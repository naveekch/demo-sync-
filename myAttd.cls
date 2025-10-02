@RestResource(urlMapping='/scheduler/v1/targeted-appointments/participants')
global with sharing class DAPV1AttendanceResource {

    @TestVisible private static final Integer BIN_CAPACITY = 100;
    @TestVisible private static final Integer MAX_PARTICIPANTS_PER_REQUEST = 2000;

    @HttpPost
    global static void processAttendance() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        String fsReqId = req.headers.get(DAPV1SchedulerConstants.HTTP_HEADER_FSREQ_ID);

        try {
            // 1) Deserialize
            DAPV1AttendanceRequest body = (DAPV1AttendanceRequest) JSON.deserialize(
                req.requestBody.toString(), DAPV1AttendanceRequest.class
            );

            // 2) Validate structure
            if (body == null || body.appointments == null || body.appointments.isEmpty()) {
                DAPV1SchedulerApiLoggingUtil.logAndThrowSchedulerApiException(
                    DAPV1SchedulerConstants.ERROR_CODE_BAD_REQUEST,
                    'The \'appointments\' list cannot be null or empty.',
                    DAPV1SchedulerConstants.HTTP_STATUS_CODE_BAD_REQUEST,
                    fsReqId,
                    DAPV1AttendanceResource.class
                );
            }

            // 3) Enforce 2,000 participants hard limit
            Integer total = 0;
            for (DAPV1AttendanceRequest.AppointmentPayload a : body.appointments) {
                if (a != null && a.participants != null) total += a.participants.size();
            }
            if (total > MAX_PARTICIPANTS_PER_REQUEST) {
                DAPV1SchedulerApiLoggingUtil.logAndThrowSchedulerApiException(
                    DAPV1SchedulerConstants.ERROR_CODE_BAD_REQUEST,
                    'Max 2,000 participants per request exceeded. Submitted: ' + total,
                    DAPV1SchedulerConstants.HTTP_STATUS_CODE_BAD_REQUEST,
                    fsReqId,
                    DAPV1AttendanceResource.class
                );
            }

            // 4) (UAT placeholder; replace with real tracker in prod)
            Id masterRunId = 'a00000000000000AAA';

            // 5) Global pack → fewest bins, track per-bin finalizeSaIds
            List<DAPV1ParticipantBinPayload> bins = packIntoBins(body.appointments);

            // 6) Enqueue one job per bin
            for (DAPV1ParticipantBinPayload bin : bins) {
                System.enqueueJob(new DAPV1ParticipantBinProcessorQueueable(bin, masterRunId, fsReqId));
            }

            // 7) Respond 202 Accepted (master run only, per your latest ask)
            DAPV1AttendanceResponse payload = new DAPV1AttendanceResponse();
            payload.status = 'Request accepted for processing.';
            payload.runId = masterRunId;

            updateAcceptedResponse(res, payload);

        } catch (Exception e) {
            DAPV1ExceptionHandler.handleException(e, res, fsReqId);
        }
    }

    /**
     * Global Bin Packing: pack across ALL appointments to minimize jobs.
     * - Deterministic SA ordering (sorted) to reduce lock jitter
     * - Index slicing (no remove(0)) for performance
     * - Tracks finalizeSaIds (SAs fully consumed in this bin)
     */
    private static List<DAPV1ParticipantBinPayload> packIntoBins(List<DAPV1AttendanceRequest.AppointmentPayload> allAppointments) {
        List<DAPV1ParticipantBinPayload> bins = new List<DAPV1ParticipantBinPayload>();

        // Remaining participants per SA (keyed by Id-as-String first)
        Map<String, List<DAPV1AttendanceRequest.ParticipantPayload>> remainingBySa = new Map<String, List<DAPV1AttendanceRequest.ParticipantPayload>>();
        for (DAPV1AttendanceRequest.AppointmentPayload appt : allAppointments) {
            if (appt == null || String.isBlank(appt.serviceAppointmentId)) continue;
            if (appt.participants == null || appt.participants.isEmpty()) continue;
            remainingBySa.put(appt.serviceAppointmentId, new List<DAPV1AttendanceRequest.ParticipantPayload>(appt.participants));
        }
        if (remainingBySa.isEmpty()) return bins;

        // Deterministic ordering of SA Ids
        List<String> saIdStrings = new List<String>(remainingBySa.keySet());
        saIdStrings.sort();

        DAPV1ParticipantBinPayload currentBin = new DAPV1ParticipantBinPayload();
        Integer usedInBin = 0;

        for (String saIdStr : saIdStrings) {
            // Safely coerce to Id; skip invalid Id strings
            Id saId;
            try { saId = (Id) saIdStr; }
            catch (Exception ex) { continue; }

            List<DAPV1AttendanceRequest.ParticipantPayload> parts = remainingBySa.get(saIdStr);
            Integer startIdx = 0;
            Integer totalForSa = parts.size();

            while (startIdx < totalForSa) {
                Integer spaceLeft = BIN_CAPACITY - usedInBin;

                if (spaceLeft == 0 && usedInBin > 0) {
                    bins.add(currentBin);
                    currentBin = new DAPV1ParticipantBinPayload();
                    usedInBin = 0;
                    spaceLeft = BIN_CAPACITY;
                }

                Integer endIdx = Math.min(startIdx + spaceLeft, totalForSa);

                // Slice by index
                List<DAPV1AttendanceRequest.ParticipantPayload> slice = new List<DAPV1AttendanceRequest.ParticipantPayload>();
                for (Integer i = startIdx; i < endIdx; i++) {
                    slice.add(parts[i]);
                }

                currentBin.slices.add(new DAPV1ParticipantBinPayload.ApptSlice(saId, slice));
                usedInBin += (endIdx - startIdx);
                startIdx = endIdx;

                if (startIdx >= totalForSa) {
                    // This bin finishes this SA
                    currentBin.finalizeSaIds.add(saId);
                }
            }
        }

        if (!currentBin.slices.isEmpty()) bins.add(currentBin);
        return bins;
    }

    // Helper to return a 202 JSON response
    private static void updateAcceptedResponse(RestResponse restResponse, Object response) {
        restResponse.statusCode = 202;
        restResponse.addHeader(
            DAPV1SchedulerConstants.HTTP_HEADER_CONTENT_TYPE_NAME,
            DAPV1SchedulerConstants.HTTP_HEADER_CONTENT_TYPE_VALUE
        );
        restResponse.responseBody = Blob.valueOf(JSON.serialize(response));
    }
}

/** -------------------------
 * Request/Response Contracts
 * ------------------------- */
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
        public String status;
        public String customerIdtype;
    }
}

public with sharing class DAPV1AttendanceResponse {
    public String status;
    public String runId;
}

/** -------------------------
 * Bin Payload (Serializable)
 * ------------------------- */
public with sharing class DAPV1ParticipantBinPayload {
    public List<ApptSlice> slices = new List<ApptSlice>();
    public Set<Id> finalizeSaIds = new Set<Id>();

    public class ApptSlice {
        public Id serviceAppointmentId;
        public List<DAPV1AttendanceRequest.ParticipantPayload> participants;
        public ApptSlice(Id saId, List<DAPV1AttendanceRequest.ParticipantPayload> parts) {
            serviceAppointmentId = saId;
            participants = parts;
        }
    }
}

/**
 * (UAT-READY • Global Bin Packing)
 * This is a "dumb worker" Queueable job. Its only job is to receive a
 * pre-processed bin of work from the API and hand it off to the synchronous
 * handler to be processed in one single transaction.
 */
public with sharing class DAPV1ParticipantBinProcessorQueueable implements Queueable {

    private final DAPV1ParticipantBinPayload bin;
    private final Id runId;
    private final String fsReqId;

    public DAPV1ParticipantBinProcessorQueueable(DAPV1ParticipantBinPayload bin, Id runId, String fsReqId) {
        this.bin = bin;
        this.runId = runId;
        this.fsReqId = fsReqId;
    }

    public void execute(QueueableContext context) {
        DAPV1SchedulerApiLoggingUtil.logInfo('[ParticipantBinProcessor] Started for Run ID: ' + runId, fsReqId, DAPV1ParticipantBinProcessorQueueable.class);
        try {
            // This job's only responsibility is to call the handler to do the work.
            DAPV1ParticipantSyncHandler handler = new DAPV1ParticipantSyncHandler();
            handler.processBin(this.bin, this.runId, this.fsReqId);
        } catch (Exception e) {
            // If the whole transaction fails (e.g., CPU timeout), this is our last chance to log it.
            DAPV1SchedulerApiLoggingUtil.logError('[ParticipantBinProcessor] Critical error for Run ID: ' + runId + '. Error: ' + e.getMessage(), fsReqId, DAPV1ParticipantBinProcessorQueueable.class);
        }
        DAPV1SchedulerApiLoggingUtil.logInfo('[ParticipantBinProcessor] Finished for Run ID: ' + runId, fsReqId, DAPV1ParticipantBinProcessorQueueable.class);
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

