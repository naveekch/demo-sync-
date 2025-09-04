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
        System.debug(LoggingLevel.INFO, 'DAPV1AttendanceResource started.');

        try {
            // 1. Deserialize the incoming JSON payload into our request object
            System.debug(LoggingLevel.INFO, 'Deserializing request body...');
            DAPV1AttendanceRequest requestBody = (DAPV1AttendanceRequest) JSON.deserialize(
                req.requestBody.toString(),
                DAPV1AttendanceRequest.class
            );
            System.debug(LoggingLevel.INFO, 'Deserialization successful. Found ' + requestBody.appointments.size() + ' appointments in payload.');

            // 2. Basic validation: ensure the top-level appointments list is not empty
            if (requestBody.appointments == null || requestBody.appointments.isEmpty()) {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf('{"error": "The \'appointments\' list cannot be null or empty."}');
                return;
            }

            // 3. Enqueue the first-stage asynchronous job (the Dispatcher).
            // This hands off the entire payload for safe background processing.
            Id jobId = System.enqueueJob(new BulkDispatcherQueueable(requestBody.appointments));
            System.debug(LoggingLevel.INFO, 'Enqueued BulkDispatcherQueueable. Job ID: ' + jobId);

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
            System.debug(LoggingLevel.ERROR, 'Error in DAPV1AttendanceResource: ' + e.getMessage());
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"error": "' + e.getMessage() + '"}');
        }
        System.debug(LoggingLevel.INFO, 'DAPV1AttendanceResource finished.');
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
        System.debug(LoggingLevel.INFO, 'BulkDispatcherQueueable started. Processing ' + appointments.size() + ' appointments.');
        // Loop through each appointment from the original payload
        for (DAPV1AttendanceRequest.AppointmentPayload appt : this.appointments) {
            // For each appointment, enqueue a new, separate Processor job.
            if (appt.participants != null && !appt.participants.isEmpty()) {
                System.debug(LoggingLevel.INFO, 'Enqueuing BulkProcessorQueueable for SA ID: ' + appt.serviceAppointmentId + ' with ' + appt.participants.size() + ' participants.');
                System.enqueueJob(new BulkProcessorQueueable(appt.serviceAppointmentId, appt.participants));
            }
        }
        System.debug(LoggingLevel.INFO, 'BulkDispatcherQueueable finished.');
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
        System.debug(LoggingLevel.INFO, 'BulkProcessorQueueable started for SA ID: ' + serviceAppointmentId + '. Total participants to process: ' + participants.size());
        
        // Create a list for the current chunk we are going to process in this single job.
        List<DAPV1AttendanceRequest.ParticipantPayload> currentChunk = new List<DAPV1AttendanceRequest.ParticipantPayload>();

        // Move records from the main list to the current chunk, up to our defined CHUNK_SIZE
        while (currentChunk.size() < CHUNK_SIZE && !participants.isEmpty()) {
            currentChunk.add(participants.remove(0));
        }
        System.debug(LoggingLevel.INFO, 'Processing chunk of ' + currentChunk.size() + ' participants.');

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
                System.debug(LoggingLevel.INFO, 'Chaining job for SA ID: ' + serviceAppointmentId + '. Remaining participants: ' + participants.size());
                System.enqueueJob(new BulkProcessorQueueable(this.serviceAppointmentId, participants));
            } else {
                 System.debug(LoggingLevel.INFO, 'All participants processed for SA ID: ' + serviceAppointmentId + '. End of chain.');
            }
        }
        System.debug(LoggingLevel.INFO, 'BulkProcessorQueueable finished for current chunk.');
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
        System.debug(LoggingLevel.INFO, 'DAPV1BulkPartCreateUseCaseHandler started for SA ID: ' + serviceAppointmentId);

        // 1. Validate the Service Appointment ID
        ServiceAppointment parentAppointment = getServiceAppointment(serviceAppointmentId);
        if (parentAppointment == null) {
            System.debug(LoggingLevel.ERROR, 'Halting processing because Service Appointment was not found.');
            return; 
        }
        System.debug(LoggingLevel.INFO, 'Service Appointment validated successfully.');

        // --- Deduplication Logic ---
        // 2. Find all existing participants for this event in a single, bulkified query
        Map<String, DAP_Event_Participant__c> existingParticipantsMap = getExistingParticipants(serviceAppointmentId, participants);
        System.debug(LoggingLevel.INFO, 'Found ' + existingParticipantsMap.size() + ' existing participants for this event.');

        List<DAP_Event_Participant__c> participantsToInsert = new List<DAP_Event_Participant__c>();
        List<DAP_Event_Participant__c> participantsToUpdate = new List<DAP_Event_Participant__c>();

        // Loop through the incoming data to determine what needs to be inserted vs. updated
        for (DAPV1AttendanceRequest.ParticipantPayload p : participants) {
            // Check if a participant with this externalId already exists for this event
            if (existingParticipantsMap.containsKey(p.externalId)) {
                // It's an UPDATE. Get the existing record and update its status.
                DAP_Event_Participant__c existingParticipant = existingParticipantsMap.get(p.externalId);
                existingParticipant.Status__c = p.status; // Update status
                participantsToUpdate.add(existingParticipant);
            } else {
                // It's a new INSERT. Create a new participant record.
                DAP_Event_Participant__c newParticipant = new DAP_Event_Participant__c(
                    Service_Appointment__c = serviceAppointmentId,
                    Notification_Email__c = p.email,
                    Status__c = p.status,
                    Meeting_Method__c = 'Virtual' // <-- BUG FIX: Add the required Meeting Method
                );
                
                /*
                // --- POC: Future fields Commented Out ---
                // These fields do not exist yet, so they are commented out.
                
                // newParticipant.ExternalId__c = p.externalId;
                // newParticipant.CustomerIdType__c = p.customerIdtype;
                */

                /*
                // --- Production: Customer Matching & Lead Creation Logic (Future State) ---
                // This logic is commented out for the POC but will be implemented for production.
                
                // Map<String, Id> externalIdToAccountIdMap = getMatchingAccounts(participants);
                // List<Lead> leadsToInsert = new List<Lead>();

                // if (externalIdToAccountIdMap.containsKey(p.externalId)) {
                //     newParticipant.Account__c = externalIdToAccountIdMap.get(p.externalId);
                // } else {
                //     leadsToInsert.add(new Lead(
                //         FirstName = p.firstName,
                //         LastName = p.lastName,
                //         Email = p.email,
                //         Company = 'Unknown', // Required field
                //         Status = 'New'
                //     ));
                // }
                */
                participantsToInsert.add(newParticipant);
            }
        }
        System.debug(LoggingLevel.INFO, 'Prepared ' + participantsToInsert.size() + ' records for insert and ' + participantsToUpdate.size() + ' for update.');

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
            System.debug(LoggingLevel.INFO, 'Updating parent Service Appointment status.');
            DAPV1SObjSrvcApptDmlAccessor apptAccessor = new DAPV1SObjSrvcApptDmlAccessor();
            apptAccessor.updateTrgtSrvcApptStatus(parentAppointment, 'Published with Registrations');
        }
        System.debug(LoggingLevel.INFO, 'DAPV1BulkPartCreateUseCaseHandler finished.');
    }

    private ServiceAppointment getServiceAppointment(String appointmentId) {
        try {
            return this.eventAudienceDmlAccessor.getEventDetail(appointmentId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Service Appointment with ID ' + appointmentId + ' not found.');
            return null;
        }
    }
    
    /**
     * @description Gets all existing participants for a given event and a list of external IDs.
     */
    private Map<String, DAP_Event_Participant__c> getExistingParticipants(String serviceAppointmentId, List<DAPV1AttendanceRequest.ParticipantPayload> participants) {
        // Collect all unique external IDs from the incoming payload
        Set<String> externalIds = new Set<String>();
        for(DAPV1AttendanceRequest.ParticipantPayload p : participants) {
            if(String.isNotBlank(p.externalId)) {
                externalIds.add(p.externalId);
            }
        }

        // Perform a single, bulkified query to find all matching records
        Map<String, DAP_Event_Participant__c> results = new Map<String, DAP_Event_Participant__c>();
        if(!externalIds.isEmpty()) {
            for(DAP_Event_Participant__c ep : [
                SELECT Id, ExternalId__c, Status__c
                FROM DAP_Event_Participant__c
                WHERE Service_Appointment__c = :serviceAppointmentId
                AND ExternalId__c IN :externalIds
            ]) {
                // Organize the results into a Map for fast lookups
                results.put(ep.ExternalId__c, ep);
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
        System.debug(LoggingLevel.INFO, 'DAPV1BulkPartDmlAccessor: Attempting to insert ' + participants.size() + ' participant records.');
        try {
            // Using Database.insert with 'false' allows for partial success.
            Database.SaveResult[] saveResults = Database.insert(participants, false);
            logErrors(saveResults, participants);
        } catch (Exception e) {
             System.debug(LoggingLevel.ERROR, 'An unexpected error occurred during participant insert: ' + e.getMessage());
        }
    }

    public void updateParticipants(List<DAP_Event_Participant__c> participants) {
        System.debug(LoggingLevel.INFO, 'DAPV1BulkPartDmlAccessor: Attempting to update ' + participants.size() + ' participant records.');
        try {
            // Using Database.update with 'false' allows for partial success.
            Database.SaveResult[] saveResults = Database.update(participants, false);
            logErrors(saveResults, participants);
        } catch (Exception e) {
             System.debug(LoggingLevel.ERROR, 'An unexpected error occurred during participant update: ' + e.getMessage());
        }
    }

    /**
     * @description A helper method to loop through DML results and log any failures.
     */
    private void logErrors(Database.SaveResult[] results, List<DAP_Event_Participant__c> records) {
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                Database.Error error = results[i].getErrors()[0];
                DAP_Event_Participant__c failedRecord = records[i];
                // For the POC, we can't log ExternalId as it doesn't exist yet.
                // We'll log the email as an identifier instead.
                System.debug(LoggingLevel.ERROR, 'Failed to process participant record. ' +
                    'Email: ' + failedRecord.Notification_Email__c + 
                    '. Error: ' + error.getStatusCode() + ' - ' + error.getMessage());
            }
        }
    }
}

