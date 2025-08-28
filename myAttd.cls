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

            // 3. Enqueue the first-stage asynchronous job (the Dispatcher)
            // This hands off the entire payload for background processing.
            Id jobId = System.enqueueJob(new BulkDispatcherQueueable(requestBody.appointments));

            // 4. Immediately return a 202 Accepted response.
            // This tells the client we'vereceived the request and it's queued for processing.
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
    public List<AppointmentPayload> appointments;

    public class AppointmentPayload {
        public String serviceAppointmentId;
        public List<ParticipantPayload> participants;
    }

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
 * This first-stage background job receives the entire list of appointments. Its only
 * purpose is to "fan out" the work by creating one "Processor" job for each appointment.
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
            // This breaks the large request into small, independent, and safe units of work.
            if (appt.participants != null && !appt.participants.isEmpty()) {
                System.enqueueJob(new BulkProcessorQueueable(appt.serviceAppointmentId, appt.participants));
            }
        }
    }
}


/**
 * @description The "Processor" Queueable job.
 * This second-stage background job does the actual work of processing all participants
 * for a SINGLE Service Appointment.
 */
public with sharing class BulkProcessorQueueable implements Queueable {

    private final String serviceAppointmentId;
    private final List<DAPV1AttendanceRequest.ParticipantPayload> participants;

    public BulkProcessorQueueable(String serviceAppointmentId, List<DAPV1AttendanceRequest.ParticipantPayload> participants) {
        this.serviceAppointmentId = serviceAppointmentId;
        this.participants = participants;
    }

    public void execute(QueueableContext context) {
        try {
            // Instantiate the Use Case Handler to orchestrate the business logic
            DAPV1BulkPartCreateUseCaseHandler handler = new DAPV1BulkPartCreateUseCaseHandler();
            handler.handle(this.serviceAppointmentId, this.participants);
        } catch (Exception e) {
            // In a production scenario, log this error to a custom logging object
            System.debug(LoggingLevel.ERROR, 'Failed to process participants for Appointment ID ' +
                this.serviceAppointmentId + '. Error: ' + e.getMessage());
        }
    }
}


/**
 * @description The "Core Engine" or Use Case Handler.
 * Contains the main business logic for processing a list of participants for one event.
 */
public with sharing class DAPV1BulkPartCreateUseCaseHandler {

    // Re-use the existing accessor from the 1:1 flow for all Service Appointment queries
    @TestVisible
    private DAPV1SObjEvntAudnceDmlAccessor eventAudienceDmlAccessor = new DAPV1SObjEvntAudnceDmlAccessor();

    public void handle(String serviceAppointmentId, List<DAPV1AttendanceRequest.ParticipantPayload> participants) {
        // 1. Validate the Service Appointment ID by reusing the existing accessor
        ServiceAppointment parentAppointment = getServiceAppointment(serviceAppointmentId);
        if (parentAppointment == null) {
            // Error is logged in the getServiceAppointment method
            return;
        }

        /*
        // --- POC: Customer Matching Logic Commented Out ---
        // 2. Perform Customer Matching in Bulk
        Map<String, Id> externalIdToAccountIdMap = getMatchingAccounts(participants);
        
        List<Lead> leadsToInsert = new List<Lead>();
        */

        List<DAP_Event_Participant__c> participantsToInsert = new List<DAP_Event_Participant__c>();

        for (DAPV1AttendanceRequest.ParticipantPayload p : participants) {
            DAP_Event_Participant__c newParticipant = new DAP_Event_Participant__c(
                Service_Appointment__c = serviceAppointmentId,
                ExternalId__c = p.externalId,
                CustomerIdType__c = p.customerIdtype,
                Notification_Email__c = p.email,
                Status__c = p.status
                // Participant_Notes__c would be mapped from p.participantNotes if it existed
            );

            /*
            // --- POC: Account/Lead Linking Logic Commented Out ---
            // 3. Link to Account or Prepare a New Lead
            if (externalIdToAccountIdMap.containsKey(p.externalId)) {
                newParticipant.Account__c = externalIdToAccountIdMap.get(p.externalId);
            } else {
                // If no matching account, create a new Lead.
                leadsToInsert.add(new Lead(
                    FirstName = p.firstName,
                    LastName = p.lastName,
                    Email = p.email,
                    Company = 'Unknown', // Required field
                    Status = 'New'
                ));
            }
            */
            participantsToInsert.add(newParticipant);
        }

        /*
        // --- POC: Lead Insertion Logic Commented Out ---
        // 4. Insert any new Leads first
        if (!leadsToInsert.isEmpty()) {
            Database.SaveResult[] leadSaveResults = Database.insert(leadsToInsert, false);
            // Now, link the participants to the newly created leads
            Integer leadIndex = 0;
            for(Integer i = 0; i < participantsToInsert.size(); i++){
                if(participantsToInsert[i].Account__c == null && leadIndex < leadSaveResults.size()){
                    if(leadSaveResults[leadIndex].isSuccess()){
                        participantsToInsert[i].Lead__c = leadSaveResults[leadIndex].getId();
                    }
                    leadIndex++;
                }
            }
        }
        */

        // 5. Insert the Event Participants
        if (!participantsToInsert.isEmpty()) {
            DAPV1BulkPartDmlAccessor dmlAccessor = new DAPV1BulkPartDmlAccessor();
            dmlAccessor.insertParticipants(participantsToInsert);

            // 6. Update the parent Service Appointment status using the existing accessor
            DAPV1SObjSrvcApptDmlAccessor apptAccessor = new DAPV1SObjSrvcApptDmlAccessor();
            parentAppointment.Status = 'Published with Registrations';
            apptAccessor.updateTrgtSrvcApptStatus(parentAppointment, 'Published with Registrations');
        }
    }

    /**
     * @description Re-usable method to safely get a Service Appointment, mirroring the 1:1 flow's pattern.
     */
    private ServiceAppointment getServiceAppointment(String appointmentId) {
        try {
            return this.eventAudienceDmlAccessor.getEventDetail(appointmentId);
        } catch (Exception e) {
            // In a production scenario, this would throw a specific exception type
            System.debug(LoggingLevel.ERROR, 'Service Appointment with ID ' + appointmentId + ' not found.');
            return null;
        }
    }

    /**
     * @description Queries for all matching Accounts in a single, bulkified query.
     */
    private Map<String, Id> getMatchingAccounts(List<DAPV1AttendanceRequest.ParticipantPayload> participants) {
        Set<String> externalIds = new Set<String>();
        for (DAPV1AttendanceRequest.ParticipantPayload p : participants) {
            if (String.isNotBlank(p.externalId)) {
                externalIds.add(p.externalId);
            }
        }

        Map<String, Id> results = new Map<String, Id>();
        if (!externalIds.isEmpty()) {
            // NOTE: Assumes a custom field 'MID__c' on Account for matching.
            for (Account acc : [SELECT Id, MID__c FROM Account WHERE MID__c IN :externalIds]) {
                results.put(acc.MID__c, acc.Id);
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
            // Perform the single, bulkified DML operation.
            // Using Database.insert with 'false' allows for partial success.
            Database.SaveResult[] saveResults = Database.insert(participants, false);

            // Loop through results to log any failures
            for (Integer i = 0; i < saveResults.size(); i++) {
                if (!saveResults[i].isSuccess()) {
                    // For the POC, we just log to the debug log.
                    Database.Error error = saveResults[i].getErrors()[0];
                    System.debug(LoggingLevel.ERROR, 'Failed to insert participant record. ' +
                        'ExternalId: ' + participants[i].ExternalId__c + 
                        '. Error: ' + error.getStatusCode() + ' - ' + error.getMessage());
                }
            }

        } catch (Exception e) {
            // Catch any unexpected DML exceptions
             System.debug(LoggingLevel.ERROR, 'An unexpected error occurred during participant insert: ' + e.getMessage());
        }
    }
}
