/**
 * This is the main entrypoint for the bulk attendance API.
 * It's designed to be a fast, synchronous "hand-off". It takes the big payload,
 * uses a "bin packing" algorithm to break it into safe chunks, and then enqueues
 * a separate job for each chunk.
 */
@RestResource(urlMapping='/scheduler/v1/attendance')
global with sharing class DAPV1AttendanceResource {

    // The max number of participants we'll stuff into a single background job.
    @TestVisible private static final Integer BIN_CAPACITY = 500;

    @HttpPost
    global static void processAttendance() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        
        try {
            DAPV1AttendanceRequest requestBody = (DAPV1AttendanceRequest) JSON.deserialize(
                req.requestBody.toString(), DAPV1AttendanceRequest.class
            );

            if (requestBody == null || requestBody.appointments == null || requestBody.appointments.isEmpty()) {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf('{"error": "The \'appointments\' list cannot be null or empty."}');
                return;
            }

            List<List<DAPV1AttendanceRequest.AppointmentPayload>> bins = packIntoBins(requestBody.appointments);

            for (List<DAPV1AttendanceRequest.AppointmentPayload> bin : bins) {
                if (!bin.isEmpty()) {
                    // Enqueue the "All-in-One" processor job for the test
                    System.enqueueJob(new DAPV1ParticipantBinProcessorQueueable(bin));
                }
            }

            res.statusCode = 202;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, String>{
                'status' => 'Request accepted for processing.',
                'jobId' => 'Multiple jobs enqueued (' + bins.size() + ' bins created)'
            }));

        } catch (Exception e) {
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"error": "' + e.getMessage() + '"}');
        }
    }
    
    // The bin packing logic remains the same.
    private static List<List<DAPV1AttendanceRequest.AppointmentPayload>> packIntoBins(List<DAPV1AttendanceRequest.AppointmentPayload> allAppointments) {
        List<List<DAPV1AttendanceRequest.AppointmentPayload>> bins = new List<List<DAPV1AttendanceRequest.AppointmentPayload>>();
        List<Integer> binCounts = new List<Integer>();
        Set<String> processedAppointmentIds = new Set<String>();

        for (DAPV1AttendanceRequest.AppointmentPayload appt : allAppointments) {
            if (appt == null || String.isBlank(appt.serviceAppointmentId)) continue;
            if (processedAppointmentIds.contains(appt.serviceAppointmentId)) continue;

            Integer participantCount = (appt.participants != null) ? appt.participants.size() : 0;
            if (participantCount == 0) continue;

            Boolean placed = false;
            for (Integer i = 0; i < bins.size(); i++) {
                if (binCounts[i] + participantCount <= BIN_CAPACITY) {
                    bins[i].add(appt);
                    binCounts[i] += participantCount;
                    placed = true;
                    break;
                }
            }

            if (!placed) {
                bins.add(new List<DAPV1AttendanceRequest.AppointmentPayload>{ appt });
                binCounts.add(participantCount);
            }
            
            processedAppointmentIds.add(appt.serviceAppointmentId);
        }
        return bins;
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
 * [TEST VERSION - "All-in-One" Model]
 * This is the "marathon runner" version of our processor. Its only job is to kick off the
 * handler to process the ENTIRE bin of appointments in one single, large transaction.
 *
 * This is simpler than chaining, but it's risky because a big, complex bin could hit the
 * 60-second CPU limit in a busy production org. We're using this to test the limits.
 */
public with sharing class DAPV1ParticipantBinProcessorQueueable implements Queueable {

    private final List<DAPV1AttendanceRequest.AppointmentPayload> appointmentsInBin;

    public DAPV1ParticipantBinProcessorQueueable(List<DAPV1AttendanceRequest.AppointmentPayload> appointmentsInBin) {
        this.appointmentsInBin = appointmentsInBin;
    }

    public void execute(QueueableContext context) {
        System.debug(LoggingLevel.INFO, '[AllInOneProcessor] Started. Processing ' + appointmentsInBin.size() + ' appointments in a single transaction.');
        
        try {
            // This job's only responsibility is to call the handler to do the work.
            DAPV1ParticipantSyncHandler handler = new DAPV1ParticipantSyncHandler();
            handler.processParticipantsInBin(this.appointmentsInBin);
        } catch (Exception e) {
            // If the whole transaction fails (e.g., CPU timeout), this is our last chance to log it.
            System.debug(LoggingLevel.ERROR, '[AllInOneProcessor] Critical error during processing: ' + e.getMessage() + ' Stacktrace: ' + e.getStackTraceString());
        }

        System.debug(LoggingLevel.INFO, '[AllInOneProcessor] Finished.');
    }
}

/**
 * [TEST VERSION - "All-in-One" Model]
 * This is the synchronous "core engine" for our test. It's designed to be a "power worker"
 * that gathers all data from an entire bin, does all the lookups, and then performs
 * all the database operations in a few, large bulk DML statements.
 */
public with sharing class DAPV1ParticipantSyncHandler {
    
    // We'll call the existing accessor classes from the 1:1 flow.
    @TestVisible private DAPV1SObjSrvcApptDmlAccessor apptAccessor = new DAPV1SObjSrvcApptDmlAccessor();
    @TestVisible private DAPV1SObjEvntAudnceDmlAccessor eventAudienceAccessor = new DAPV1SObjEvntAudnceDmlAccessor();

    public void processParticipantsInBin(List<DAPV1AttendanceRequest.AppointmentPayload> bin) {
        // We'll create master lists to hold all the records we're going to process.
        List<DAP_Event_Participant__c> allParticipantsToInsert = new List<DAP_Event_Participant__c>();
        List<DAP_Event_Participant__c> allParticipantsToUpdate = new List<DAP_Event_Participant__c>();
        Set<String> allServiceAppointmentIds = new Set<String>();
        Map<String, List<DAPV1AttendanceRequest.ParticipantPayload>> participantsByAppointment = new Map<String, List<DAPV1AttendanceRequest.ParticipantPayload>>();

        // --- Step 1: First, just gather and organize all the data from the bin ---
        for (DAPV1AttendanceRequest.AppointmentPayload appt : bin) {
            if (appt == null || String.isBlank(appt.serviceAppointmentId) || appt.participants == null || appt.participants.isEmpty()) continue;
            
            allServiceAppointmentIds.add(appt.serviceAppointmentId);
            participantsByAppointment.put(appt.serviceAppointmentId, appt.participants);
        }

        if (allServiceAppointmentIds.isEmpty()) return;

        // --- Step 2: Now, do one big database query to find all existing participants ---
        Map<String, DAP_Event_Participant__c> existingParticipantsMap = getExistingParticipants(participantsByAppointment);

        // --- Step 3: Loop through the data and prepare the records for DML ---
        for (String saId : participantsByAppointment.keySet()) {
            for (DAPV1AttendanceRequest.ParticipantPayload p : participantsByAppointment.get(saId)) {
                // We create a "composite key" to uniquely identify a registration
                // for one person at one specific event.
                String compositeKey = saId + '-' + p.externalId;
                String normalizedStatus = normalizeStatus(p.status);

                if (existingParticipantsMap.containsKey(compositeKey)) {
                    // If we found a match, we update the existing record.
                    DAP_Event_Participant__c ep = existingParticipantsMap.get(compositeKey);
                    ep.Status__c = normalizedStatus;
                    allParticipantsToUpdate.add(ep);
                } else {
                    // If no match, we create a new record.
                    DAP_Event_Participant__c ep = new DAP_Event_Participant__c(
                        Service_Appointment__c = saId,
                        ExternalId__c = p.externalId,
                        Notification_Email__c = p.email,
                        Status__c = normalizedStatus,
                        Meeting_Method__c = 'Virtual'
                    );
                    allParticipantsToInsert.add(ep);
                }
            }
        }
        
        // --- Step 4: Perform all database operations for the entire bin at once ---
        DAPV1ParticipantDmlAccessor dmlAccessor = new DAPV1ParticipantDmlAccessor();
        if (!allParticipantsToInsert.isEmpty()) {
            dmlAccessor.insertParticipants(allParticipantsToInsert);
        }
        if (!allParticipantsToUpdate.isEmpty()) {
            dmlAccessor.updateParticipants(allParticipantsToUpdate);
        }

        // --- Step 5: Finally, update all the parent Service Appointment statuses ---
        finalizeAppointmentStatuses(allServiceAppointmentIds);
    }
    
    // This method updates all the parent statuses in one bulk DML statement for efficiency.
    private void finalizeAppointmentStatuses(Set<String> serviceAppointmentIds) {
        // The "FOR UPDATE" clause is a critical safety feature. It locks these specific
        // rows in the database, which prevents race conditions if another API call
        // tries to update the same appointments at the exact same time.
        List<ServiceAppointment> appointmentsToUpdate = [
            SELECT Id, Status FROM ServiceAppointment WHERE Id IN :serviceAppointmentIds FOR UPDATE
        ];
        for (ServiceAppointment sa : appointmentsToUpdate) {
            // We only update the status if it's not already correct, to avoid
            // firing unnecessary triggers and automation.
            if (sa.Status != 'Published with Registrations') {
                sa.Status = 'Published with Registrations';
            }
        }
        if(!appointmentsToUpdate.isEmpty()){
             this.apptAccessor.updateServiceAppointments(appointmentsToUpdate);
        }
    }

    // This is our main deduplication query. It's bulkified to run only once for the entire bin.
    private Map<String, DAP_Event_Participant__c> getExistingParticipants(Map<String, List<DAPV1AttendanceRequest.ParticipantPayload>> participantsByAppointment) {
        Set<String> externalIds = new Set<String>();
        for (String saId : participantsByAppointment.keySet()) {
            for (DAPV1AttendanceRequest.ParticipantPayload p : participantsByAppointment.get(saId)) {
                if (String.isNotBlank(p.externalId)) {
                    externalIds.add(p.externalId);
                }
            }
        }
        
        Map<String, DAP_Event_Participant__c> results = new Map<String, DAP_Event_Participant__c>();
        if(!externalIds.isEmpty()) {
            // We find all potential matches based on the appointment IDs and external IDs.
            for(DAP_Event_Participant__c ep : [
                SELECT Id, ExternalId__c, Status__c, Service_Appointment__c
                FROM DAP_Event_Participant__c
                WHERE Service_Appointment__c IN :participantsByAppointment.keySet()
                AND ExternalId__c IN :externalIds
            ]) {
                // We then put them into a Map using the composite key for a perfect match lookup.
                results.put(ep.Service_Appointment__c + '-' + ep.ExternalId__c, ep);
            }
        }
        return results;
    }
    
    // A simple helper to clean up incoming status values.
    private String normalizeStatus(String status) { 
        if (String.isBlank(status)) return 'Registered';
        String s = status.toLowerCase().trim();
        if (s == 'attended') return 'Attended';
        if (s == 'no show' || s == 'no_show') return 'No Show';
        return 'Registered';
    }
}

// DML Accessor for Participant records
public with sharing class DAPV1ParticipantDmlAccessor {
    public void insertParticipants(List<DAP_Event_Participant__c> participants) {
        try {
            Database.SaveResult[] saveResults = Database.insert(participants, false);
            logErrors(saveResults, participants);
        } catch (Exception e) {
             System.debug(LoggingLevel.ERROR, 'Unexpected error during participant insert: ' + e.getMessage());
        }
    }
    public void updateParticipants(List<DAP_Event_Participant__c> participants) {
        try {
            Database.SaveResult[] saveResults = Database.update(participants, false);
            logErrors(saveResults, participants);
        } catch (Exception e) {
             System.debug(LoggingLevel.ERROR, 'Unexpected error during participant update: ' + e.getMessage());
        }
    }
    private void logErrors(Database.SaveResult[] results, List<DAP_Event_Participant__c> records) {
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                Database.Error error = results[i].getErrors()[0];
                DAP_Event_Participant__c failedRecord = records[i];
                System.debug(LoggingLevel.ERROR, 'Failed to process participant record. ExternalId: ' + failedRecord.ExternalId__c + '. Error: ' + error.getStatusCode() + ' - ' + error.getMessage());
            }
        }
    }
}

// --- DEPENDENCY CLASS (Full implementation for methods used in this POC) ---
// This class contains the reusable methods from the 1:1 flow that our new code will call.
public with sharing class DAPV1SObjSrvcApptDmlAccessor {
    // A bulk-safe method to update a list of Service Appointments
    public void updateServiceAppointments(List<ServiceAppointment> appointments) {
        update appointments;
    }
    
    // A method to update a single Service Appointment's status
    public void updateTrgtSrvcApptStatus(SObject s, String status) { 
        ServiceAppointment sa = (ServiceAppointment)s;
        sa.Status = status;
        update sa; 
    } 
}

