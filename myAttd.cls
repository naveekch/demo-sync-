/**
 * @description Apex REST Resource for the true bulk attendance API.
 * This is the single, synchronous entry point for the LDS system. Its only job is to
 * receive the entire payload and enqueue the first-stage asynchronous job (the Dispatcher).
 * @see DAPV1AttendanceRequest
 * @see BulkDispatcherQueueable
 */
@RestResource(urlMapping='/scheduler/v1/attendance')
global with sharing class DAPV1AttendanceResource {

    @HttpPost
    global static void processAttendance() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        try {
            // 1. Deserialize the incoming JSON payload into our request object
            DAPV1AttendanceRequest requestBody = (DAPV1AttendanceRequest) JSON.deserialize(
                req.requestBody.toString(),
                DAPV1AttendanceRequest.class
            );

            // 2. Basic validation: ensure the top-level appointments list is not empty
            if (requestBody.appointments == null || requestBody.appointments.isEmpty()) {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf('{"error": "The \'appointments\' list cannot be null or empty."}');
                return;
            }

            // 3. Enqueue the first-stage asynchronous job (the Dispatcher).
            // This hands off the entire payload for safe background processing.
            Id jobId = System.enqueueJob(new BulkDispatcherQueueable(requestBody.appointments));

            // 4. Immediately return a 202 Accepted response.
            // This tells the client we've received the request and it's queued for processing.
            // It does NOT mean the processing is complete.
            res.statusCode = 202;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, String>{
                'status' => 'Request accepted for processing.',
                'jobId' => jobId
            }));

        } catch (Exception e) {
            // Handle any unexpected errors during deserialization or enqueueing
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"error": "' + e.getMessage() + '"}');
        }
    }
}

// --- Helper class for the JSON Request Body ---
public with sharing class DAPV1AttendanceRequest {
    // A list of all appointments included in this bulk request
    public List<AppointmentPayload> appointments;

    // Represents a single appointment and its list of participants
    public class AppointmentPayload {
        public String serviceAppointmentId;
        public List<ParticipantPayload> participants;
    }

    // Represents a single participant's data from the source system
    public class ParticipantPayload {
        public String externalId; // lds id
        public String firstName;
        public String lastName;
        public String email;
        public String phone;
        public String zipCode;
        public String status; // Attended/registered/no_show
        public String customerIdtype; // mid/prospectid/memberid
    }
}


/**
 * @description The "Dispatcher" Queueable job.
 * This first-stage background job receives the entire list of appointments from the API.
 * Its only purpose is to "fan out" the work by creating one "Processor" job for each
 * individual appointment, ensuring the load is broken into safe, independent chunks.
 * @see BulkProcessorQueueable
 */
public with sharing class BulkDispatcherQueueable implements Queueable {

    private final List<DAPV1AttendanceRequest.AppointmentPayload> appointments;

    public BulkDispatcherQueueable(List<DAPV1AttendanceRequest.AppointmentPayload> appointments) {
        this.appointments = appointments;
    }

    public void execute(QueueableContext context) {
        // Loop through each appointment from the original payload
        for (DAPV1AttendanceRequest.AppointmentPayload appt : this.appointments) {
            // For each appointment, enqueue a new, separate Processor job.
            // This is the "fan-out" step that makes the architecture resilient and scalable.
            if (appt.participants != null && !appt.participants.isEmpty()) {
                System.enqueueJob(new BulkProcessorQueueable(appt.serviceAppointmentId, appt.participants));
            }
        }
    }
}


/**
 * @description The "Processor" Queueable job.
 * This second-stage background job does the actual work of processing all participants
 * for a SINGLE Service Appointment. It includes "chaining" logic to handle large volumes.
 */
public with sharing class BulkProcessorQueueable implements Queueable {

    // Define a safe number of records to process in one transaction.
    // This can be tuned, but 1000 is a safe starting point.
    @TestVisible
    private static final Integer CHUNK_SIZE = 1000;

    private final String serviceAppointmentId;
    private final List<DAPV1AttendanceRequest.ParticipantPayload> participants;

    public BulkProcessorQueueable(String serviceAppointmentId, List<DAPV1AttendanceRequest.ParticipantPayload> participants) {
        this.serviceAppointmentId = serviceAppointmentId;
        this.participants = participants;
    }

    public void execute(QueueableContext context) {
        // --- Chaining Logic: Part 1 - Prepare the current chunk ---
        // Create a list for the current chunk we are going to process in this single job.
        List<DAPV1AttendanceRequest.ParticipantPayload> currentChunk = new List<DAPV1AttendanceRequest.ParticipantPayload>();

        // Process records up to our defined CHUNK_SIZE
        while (currentChunk.size() < CHUNK_SIZE && !participants.isEmpty()) {
            currentChunk.add(participants.remove(0));
        }

        try {
            // --- Do the actual work for the current chunk ---
            DAPV1BulkPartCreateUseCaseHandler handler = new DAPV1BulkPartCreateUseCaseHandler();
            handler.handle(this.serviceAppointmentId, currentChunk);
        } catch (Exception e) {
            // In a production scenario, log this error to a custom logging object
            System.debug(LoggingLevel.ERROR, 'Failed to process participants for Appointment ID ' +
                this.serviceAppointmentId + '. Error: ' + e.getMessage());
        } finally {
            // --- Chaining Logic: Part 2 - Enqueue the next job OR finalize the process ---
            if (!participants.isEmpty()) {
                // --- THIS IS NOT THE LAST JOB ---
                // If there are records left, create a new job with the remainder and enqueue it.
                // This is the "chaining" step that passes the work to the next link.
                System.enqueueJob(new BulkProcessorQueueable(this.serviceAppointmentId, participants));
            } else {
                // --- THIS IS THE LAST JOB IN THE CHAIN ---
                // If the participants list is now empty, all work for this appointment is done.
                // This is the correct and only place to update the parent Service Appointment's status.
                DAPV1SObjSrvcApptDmlAccessor apptAccessor = new DAPV1SObjSrvcApptDmlAccessor();
                ServiceAppointment parentAppointment = [SELECT Id, Status FROM ServiceAppointment WHERE Id = :this.serviceAppointmentId];
                if (parentAppointment != null && parentAppointment.Status != 'Published with Registrations') {
                    apptAccessor.updateTrgtSrvcApptStatus(parentAppointment, 'Published with Registrations');
                }
            }
        }
    }
}


/**
 * @description The "Core Engine" or Use Case Handler.
 * Contains the main business logic for processing a list of participants for one event.
 * This class is called by the Processor job for each chunk.
 */
public with sharing class DAPV1BulkPartCreateUseCaseHandler {

    // Re-use the existing accessor from the 1:1 flow for all Service Appointment queries
    @TestVisible
    private DAPV1SObjEvntAudnceDmlAccessor eventAudienceDmlAccessor = new DAPV1SObjEvntAudnceDmlAccessor();

    public void handle(String serviceAppointmentId, List<DAPV1AttendanceRequest.ParticipantPayload> participants) {
        // 1. Validate the Service Appointment ID by reusing the existing accessor
        ServiceAppointment parentAppointment = getServiceAppointment(serviceAppointmentId);
        if (parentAppointment == null) {
            return; // Error is logged in helper method
        }

        // --- Deduplication Logic ---
        // 2. Find all existing participants for this event in a single, bulkified query
        Map<String, DAP_Event_Participant__c> existingParticipantsMap = getExistingParticipants(serviceAppointmentId, participants);

        List<DAP_Event_Participant__c> participantsToInsert = new List<DAP_Event_Participant__c>();
        List<DAP_Event_Participant__c> participantsToUpdate = new List<DAP_Event_Participant__c>();

        for (DAPV1AttendanceRequest.ParticipantPayload p : participants) {
            if (existingParticipantsMap.containsKey(p.externalId)) {
                // It's an UPDATE.
                DAP_Event_Participant__c existingParticipant = existingParticipantsMap.get(p.externalId);
                existingParticipant.Status__c = p.status;
                participantsToUpdate.add(existingParticipant);
            } else {
                // It's a new INSERT.
                DAP_Event_Participant__c newParticipant = new DAP_Event_Participant__c(
                    Service_Appointment__c = serviceAppointmentId,
                    ExternalId__c = p.externalId,
                    CustomerIdType__c = p.customerIdtype,
                    Notification_Email__c = p.email,
                    Status__c = p.status
                );
                
                /*
                // --- Production: Customer Matching & Lead Creation Logic (Future State) ---
                // This logic is commented out for the POC but will be implemented for production.
                // It will find a matching Account based on externalId or create a new Lead.
                
                // Map<String, Id> externalIdToAccountIdMap = getMatchingAccounts(participants);
                // List<Lead> leadsToInsert = new List<Lead>();

                // if (externalIdToAccountIdMap.containsKey(p.externalId)) {
                //     newParticipant.Account__c = externalIdToAccountIdMap.get(p.externalId);
                // } else {
                //     leadsToInsert.add(new Lead(
                //         FirstName = p.firstName, LastName = p.lastName, Email = p.email,
                //         Company = 'Unknown', Status = 'New'
                //     ));
                // }
                */
                participantsToInsert.add(newParticipant);
            }
        }

        // 3. Perform DML Operations
        DAPV1BulkPartDmlAccessor dmlAccessor = new DAPV1BulkPartDmlAccessor();
        if (!participantsToInsert.isEmpty()) {
            dmlAccessor.insertParticipants(participantsToInsert);
        }
        if (!participantsToUpdate.isEmpty()) {
            dmlAccessor.updateParticipants(participantsToUpdate);
        }

        // NOTE: The final status update is now handled by the last job in the Processor chain.
    }

    private ServiceAppointment getServiceAppointment(String appointmentId) {
        try {
            return this.eventAudienceDmlAccessor.getEventDetail(appointmentId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Service Appointment with ID ' + appointmentId + ' not found.');
            return null;
        }
    }
    
    private Map<String, DAP_Event_Participant__c> getExistingParticipants(String serviceAppointmentId, List<DAPV1AttendanceRequest.ParticipantPayload> participants) {
        Set<String> externalIds = new Set<String>();
        for(DAPV1AttendanceRequest.ParticipantPayload p : participants) {
            if(String.isNotBlank(p.externalId)) {
                externalIds.add(p.externalId);
            }
        }

        Map<String, DAP_Event_Participant__c> results = new Map<String, DAP_Event_Participant__c>();
        if(!externalIds.isEmpty()) {
            for(DAP_Event_Participant__c ep : [
                SELECT Id, ExternalId__c, Status__c
                FROM DAP_Event_Participant__c
                WHERE Service_Appointment__c = :serviceAppointmentId
                AND ExternalId__c IN :externalIds
            ]) {
                results.put(ep.ExternalId__c, ep);
            }
        }
        return results;
    }
}


/**
 * @description DML Accessor for bulk participant operations.
 * Handles the actual database interactions in a bulk-safe manner.
 */
public with sharing class DAPV1BulkPartDmlAccessor {

    public void insertParticipants(List<DAP_Event_Participant__c> participants) {
        try {
            Database.SaveResult[] saveResults = Database.insert(participants, false);
            logErrors(saveResults, participants);
        } catch (Exception e) {
             System.debug(LoggingLevel.ERROR, 'An unexpected error occurred during participant insert: ' + e.getMessage());
        }
    }

    public void updateParticipants(List<DAP_Event_Participant__c> participants) {
        try {
            Database.SaveResult[] saveResults = Database.update(participants, false);
            logErrors(saveResults, participants);
        } catch (Exception e) {
             System.debug(LoggingLevel.ERROR, 'An unexpected error occurred during participant update: ' + e.getMessage());
        }
    }

    private void logErrors(Database.SaveResult[] results, List<SObject> records) {
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                Database.Error error = results[i].getErrors()[0];
                DAP_Event_Participant__c failedParticipant = (DAP_Event_Participant__c)records[i];
                System.debug(LoggingLevel.ERROR, 'Failed to process participant record. ' +
                    'ExternalId: ' + failedParticipant.ExternalId__c + 
                    '. Error: ' + error.getStatusCode() + ' - ' + error.getMessage());
            }
        }
    }
}

