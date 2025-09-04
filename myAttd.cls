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
        public String externalId; 
        public String firstName;
        public String lastName;
        public String email;
        public String phone;
        public String zipCode;
        public String status;
        public String customerIdtype;
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
    @TestVisible
    private static final Integer CHUNK_SIZE = 1000;

    private final String serviceAppointmentId;
    private final List<DAPV1AttendanceRequest.ParticipantPayload> participants;

    public BulkProcessorQueueable(String serviceAppointmentId, List<DAPV1AttendanceRequest.ParticipantPayload> participants) {
        this.serviceAppointmentId = serviceAppointmentId;
        this.participants = participants;
    }

    public void execute(QueueableContext context) {
        // Create a list for the current chunk we are going to process in this single job.
        List<DAPV1AttendanceRequest.ParticipantPayload> currentChunk = new List<DAPV1AttendanceRequest.ParticipantPayload>();

        // Move records from the main list to the current chunk, up to our defined CHUNK_SIZE
        while (currentChunk.size() < CHUNK_SIZE && !participants.isEmpty()) {
            currentChunk.add(participants.remove(0));
        }

        try {
            // Do the actual work for the current chunk
            DAPV1BulkPartCreateUseCaseHandler handler = new DAPV1BulkPartCreateUseCaseHandler();
            handler.handle(this.serviceAppointmentId, currentChunk);
        } catch (Exception e) {
            // For the POC, log any critical errors to the standard debug log.
            System.debug(LoggingLevel.ERROR, 'Failed to process participants for Appointment ID ' +
                this.serviceAppointmentId + '. Error: ' + e.getMessage());
        } finally {
            // After processing the current chunk, check if there are any records left.
            if (!participants.isEmpty()) {
                // If yes, create a new job with the remaining records and add it to the queue.
                // This is the "chaining" step.
                System.enqueueJob(new BulkProcessorQueueable(this.serviceAppointmentId, participants));
            }
        }
    }
}


/**
 * @description The "Core Engine" or Use Case Handler.
 * Contains the main business logic for processing a list of participants for one event.
 */
public with sharing class DAPV1BulkPartCreateUseCaseHandler {

    @TestVisible
    private DAPV1SObjEvntAudnceDmlAccessor eventAudienceDmlAccessor = new DAPV1SObjEvntAudnceDmlAccessor();

    public void handle(String serviceAppointmentId, List<DAPV1AttendanceRequest.ParticipantPayload> participants) {
        // 1. Validate the Service Appointment ID
        ServiceAppointment parentAppointment = getServiceAppointment(serviceAppointmentId);
        if (parentAppointment == null) {
            return; 
        }

        // --- Deduplication Logic (Using Existing Fields for POC) ---
        // 2. Find all existing participants for this event to perform an "upsert"
        Map<String, DAP_Event_Participant__c> existingParticipantsMap = getExistingParticipants(serviceAppointmentId, participants);

        List<DAP_Event_Participant__c> participantsToInsert = new List<DAP_Event_Participant__c>();
        List<DAP_Event_Participant__c> participantsToUpdate = new List<DAP_Event_Participant__c>();

        for (DAPV1AttendanceRequest.ParticipantPayload p : participants) {
            // Create a composite key for matching based on existing fields
            String compositeKey = p.firstName + p.lastName + p.email;
            
            if (existingParticipantsMap.containsKey(compositeKey)) {
                // It's an UPDATE.
                DAP_Event_Participant__c existingParticipant = existingParticipantsMap.get(compositeKey);
                existingParticipant.Status__c = p.status;
                participantsToUpdate.add(existingParticipant);
            } else {
                // It's a new INSERT.
                DAP_Event_Participant__c newParticipant = new DAP_Event_Participant__c(
                    Service_Appointment__c = serviceAppointmentId,
                    Notification_Email__c = p.email,
                    Status__c = p.status
                    // TODO: Map FirstName and LastName to the correct fields on the SObject
                );
                
                /*
                // --- POC: Future fields Commented Out ---
                // newParticipant.ExternalId__c = p.externalId;
                // newParticipant.CustomerIdType__c = p.customerIdtype;
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
        
        // 4. Update the parent Service Appointment status
        if (!participantsToInsert.isEmpty() || !participantsToUpdate.isEmpty()) {
            DAPV1SObjSrvcApptDmlAccessor apptAccessor = new DAPV1SObjSrvcApptDmlAccessor();
            apptAccessor.updateTrgtSrvcApptStatus(parentAppointment, 'Published with Registrations');
        }
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
        // Collect identifying information from the payload
        Set<String> emails = new Set<String>();
        // TODO: Add sets for first names and last names for a more precise query
        for(DAPV1AttendanceRequest.ParticipantPayload p : participants) {
            if(String.isNotBlank(p.email)) {
                emails.add(p.email);
            }
        }

        Map<String, DAP_Event_Participant__c> results = new Map<String, DAP_Event_Participant__c>();
        if(!emails.isEmpty()) {
            // Query for existing participants based on a combination of existing fields
            // NOTE: This assumes the combination of FirstName, LastName, and Email is unique per event
            for(DAP_Event_Participant__c ep : [
                SELECT Id, Status__c, /* TODO: Query for FirstName/LastName fields */ Notification_Email__c
                FROM DAP_Event_Participant__c
                WHERE Service_Appointment__c = :serviceAppointmentId
                AND Notification_Email__c IN :emails
                // TODO: Add AND FirstName IN :firstNames AND LastName IN :lastNames
            ]) {
                // Create the same composite key for the map
                String compositeKey = '' /*ep.FirstName*/ + '' /*ep.LastName*/ + ep.Notification_Email__c;
                results.put(compositeKey, ep);
            }
        }
        return results;
    }
}


/**
 * @description DML Accessor for bulk participant operations.
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

    private void logErrors(Database.SaveResult[] results, List<DAP_Event_Participant__c> records) {
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                Database.Error error = results[i].getErrors()[0];
                DAP_Event_Participant__c failedParticipant = (DAP_Event_Participant__c)records[i];
                System.debug(LoggingLevel.ERROR, 'Failed to process participant record. ' +
                    'Email: ' + failedParticipant.Notification_Email__c + 
                    '. Error: ' + error.getStatusCode() + ' - ' + error.getMessage());
            }
        }
    }
}

