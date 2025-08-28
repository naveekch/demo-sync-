/**
 * @description Apex REST Resource for the true bulk attendance API.
 * This is the single, synchronous entry point for the LDS system. Its only job is to
 * receive the entire payload and enqueue the first-stage asynchronous job (the Dispatcher).
 * @see DAPV1BulkRequest
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
            DAPV1BulkRequest requestBody = (DAPV1BulkRequest) JSON.deserialize(
                req.requestBody.toString(),
                DAPV1BulkRequest.class
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
public with sharing class DAPV1BulkRequest {
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
        public String id;
        public String timezone;
        public String meetingMethod;
        public String participantNotes;
        public String repNotes;
        public String registrantCorpId;
        public String referrerCorpId;
    }
}

// --- Utility to manage trigger execution ---
public class DAPTriggerHandlerUtil {
    @TestVisible
    public static boolean bypassEventParticipantTrigger = false;
}


/**
 * @description The "Dispatcher" Queueable job.
 * This first-stage background job receives the entire list of appointments. Its only
 * purpose is to "fan out" the work by creating one "Processor" job for each appointment.
 * @see BulkProcessorQueueable
 */
public with sharing class BulkDispatcherQueueable implements Queueable {

    private final List<DAPV1BulkRequest.AppointmentPayload> appointments;

    public BulkDispatcherQueueable(List<DAPV1BulkRequest.AppointmentPayload> appointments) {
        this.appointments = appointments;
    }

    public void execute(QueueableContext context) {
        // Loop through each appointment from the original payload
        for (DAPV1BulkRequest.AppointmentPayload appt : this.appointments) {
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
    private final List<DAPV1BulkRequest.ParticipantPayload> participants;

    public BulkProcessorQueueable(String serviceAppointmentId, List<DAPV1BulkRequest.ParticipantPayload> participants) {
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

    public void handle(String serviceAppointmentId, List<DAPV1BulkRequest.ParticipantPayload> participants) {
        List<DAP_Event_Participant__c> participantsToInsert = new List<DAP_Event_Participant__c>();

        // In a real implementation, this is where you would perform the "upsert" logic,
        // customer matching (querying for existing Contacts/Leads based on externalId),
        // and data enrichment. For this example, we'll do a direct mapping.

        for (DAPV1BulkRequest.ParticipantPayload p : participants) {
            // NOTE: Assumes corresponding custom fields exist on DAP_Event_Participant__c
            participantsToInsert.add(new DAP_Event_Participant__c(
                Service_Appointment__c = serviceAppointmentId,
                ExternalId__c = p.externalId,
                CustomerIdType__c = p.customerIdtype,
                Notification_Email__c = p.email,
                Status__c = p.status,
                Participant_Notes__c = p.participantNotes
                // Map other fields from the payload to the SObject here
            ));
        }

        if (!participantsToInsert.isEmpty()) {
            // Delegate to the DML Accessor to perform the database insert
            DAPV1BulkPartDmlAccessor dmlAccessor = new DAPV1BulkPartDmlAccessor();
            dmlAccessor.insertParticipants(participantsToInsert);

            // After successful insert, update the parent Service Appointment status
            // Note: This assumes the DmlAccessor for ServiceAppointment already exists from the 1:1 flow.
            DAPV1SObjSrvcApptDmlAccessor apptAccessor = new DAPV1SObjSrvcApptDmlAccessor();
            ServiceAppointment parentAppt = new ServiceAppointment(Id = serviceAppointmentId);
            apptAccessor.updateTrgtSrvcApptStatus(parentAppt, 'Published with Registrations');
        }
    }
}


/**
 * @description DML Accessor for bulk participant operations.
 * Handles the actual database interactions in a bulk-safe manner.
 */
public with sharing class DAPV1BulkPartDmlAccessor {

    public void insertParticipants(List<DAP_Event_Participant__c> participants) {
        // Set the flag to bypass the Event Participant trigger
        DAPTriggerHandlerUtil.bypassEventParticipantTrigger = true;

        try {
            // Perform the single, bulkified DML operation.
            // Using Database.insert with 'false' allows for partial success.
            Database.SaveResult[] saveResults = Database.insert(participants, false);

            // Loop through results to log any failures
            for (Integer i = 0; i < saveResults.size(); i++) {
                if (!saveResults[i].isSuccess()) {
                    // For the POC, we just log to the debug log.
                    // In production, this would write to a custom Integration_Log__c object.
                    Database.Error error = saveResults[i].getErrors()[0];
                    System.debug(LoggingLevel.ERROR, 'Failed to insert participant record. ' +
                        'ExternalId: ' + participants[i].ExternalId__c + // Assuming you add this field for logging
                        '. Error: ' + error.getStatusCode() + ' - ' + error.getMessage());
                }
            }

        } finally {
            // ALWAYS reset the flag, even if an error occurs, to ensure
            // the trigger works correctly for other transactions.
            DAPTriggerHandlerUtil.bypassEventParticipantTrigger = false;
        }
    }
}
