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
        public String id;
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
    private final Id binRecordId;
    private final Id runId;
    private final String fsReqId;

    public DAPV1ParticipantBinProcessorQueueable(Id binRecordId, Id runId, String fsReqId) {
        this.binRecordId = binRecordId;
        this.runId = runId;
        this.fsReqId = fsReqId;
    }

    public void execute(QueueableContext ctx) {
        DAPV1SchedulerApiLoggingUtil.logInfo(
            '[BinProcessor] Started for binId=' + binRecordId,
            fsReqId, DAPV1ParticipantBinProcessorQueueable.class
        );
        try {
            DAP_Participant_Bin__c binRow = DAPV1ParticipantBinRepository.getBin(binRecordId);
            if (binRow == null || String.isBlank(binRow.Participant_Bin__c)) {
                DAPV1SchedulerApiLoggingUtil.logError(
                    '[BinProcessor] Missing bin row or JSON for binId=' + binRecordId,
                    fsReqId, DAPV1ParticipantBinProcessorQueueable.class
                );
                DAPV1ParticipantBinRepository.markFailed(binRecordId);
                return;
            }

            DAPV1ParticipantBinPayload bin =
                (DAPV1ParticipantBinPayload) JSON.deserialize(binRow.Participant_Bin__c, DAPV1ParticipantBinPayload.class);

            // Process the bin (your existing core engine)
            new DAPV1ParticipantSyncHandler().processBin(bin, runId, fsReqId);

            // Mark completed
            DAPV1ParticipantBinRepository.markCompleted(binRecordId);

            DAPV1SchedulerApiLoggingUtil.logInfo(
                '[BinProcessor] Completed binId=' + binRecordId,
                fsReqId, DAPV1ParticipantBinProcessorQueueable.class
            );
        } catch (Exception e) {
            DAPV1ParticipantBinRepository.markFailed(binRecordId);
            DAPV1SchedulerApiLoggingUtil.logError(
                '[BinProcessor] Failed binId=' + binRecordId + ' err=' + e.getMessage(),
                fsReqId, DAPV1ParticipantBinProcessorQueueable.class
            );
        }
    }
}

public with sharing class DAPV1ParticipantSyncHandler {
    
    @TestVisible private DAPV1SObjSrvcApptDmlAccessor apptAccessor = new DAPV1SObjSrvcApptDmlAccessor();
    @TestVisible private AccountsService accountsService = new AccountsService();

    public void processBin(DAPV1ParticipantBinPayload bin, Id runId, String fsReqId) {
        // --- Step 1: Gather participants per SA (Id-keyed) ---
        Map<Id, List<DAPV1AttendanceRequest.ParticipantPayload>> bySa = new Map<Id, List<DAPV1AttendanceRequest.ParticipantPayload>>();
        for (DAPV1ParticipantBinPayload.ApptSlice slice : bin.slices) {
            if (slice == null || slice.serviceAppointmentId == null || slice.participants == null || slice.participants.isEmpty()) continue;
            if (!bySa.containsKey(slice.serviceAppointmentId)) {
                bySa.put(slice.serviceAppointmentId, new List<DAPV1AttendanceRequest.ParticipantPayload>());
            }
            bySa.get(slice.serviceAppointmentId).addAll(slice.participants);
        }
        if (bySa.isEmpty()) return;

        // --- Step 2: Validate SAs in bulk ---
        Set<Id> validSaIds = validateServiceAppointments(bySa.keySet(), fsReqId);
        if (validSaIds.isEmpty()) {
            DAPV1SchedulerApiLoggingUtil.logError('No valid Service Appointments found in this bin.', fsReqId, DAPV1ParticipantSyncHandler.class);
            return;
        }

        // --- Step 3: Dedup query (existing EPs by SA+ExternalId) ---
        Map<String, DAP_Event_Participant__c> existing = getExistingParticipants(bySa);

        // --- Step 4: Triage into updates vs inserts ---
        List<DAP_Event_Participant__c> toUpdate = new List<DAP_Event_Participant__c>();
        List<DAPV1AttendanceRequest.ParticipantPayload> newCandidates = new List<DAPV1AttendanceRequest.ParticipantPayload>();
        // Also build a reverse lookup: payload -> SA Id
        Map<DAPV1AttendanceRequest.ParticipantPayload, Id> payloadToSa = new Map<DAPV1AttendanceRequest.ParticipantPayload, Id>();

        for (Id saId : bySa.keySet()) {
            if (!validSaIds.contains(saId)) continue;
            for (DAPV1AttendanceRequest.ParticipantPayload p : bySa.get(saId)) {
                payloadToSa.put(p, saId);
                String k = String.valueOf(saId) + '-' + p.externalId;
                if (existing.containsKey(k)) {
                    DAP_Event_Participant__c ep = existing.get(k);
                    ep.Status__c = normalizeStatus(p.status);
                    toUpdate.add(ep);
                } else {
                    newCandidates.add(p);
                }
            }
        }

        // --- Step 5: Insert path (resolve Account by MID; else create Lead) ---
        List<DAP_Event_Participant__c> toInsert = new List<DAP_Event_Participant__c>();
        if (!newCandidates.isEmpty()) {
            // Split by MID vs no-MID
            List<DAPV1AttendanceRequest.ParticipantPayload> withMid = new List<DAPV1AttendanceRequest.ParticipantPayload>();
            List<DAPV1AttendanceRequest.ParticipantPayload> noMid   = new List<DAPV1AttendanceRequest.ParticipantPayload>();
            for (DAPV1AttendanceRequest.ParticipantPayload p : newCandidates) {
                if ('mid'.equalsIgnoreCase(p.customerIdtype) && String.isNotBlank(p.id)) withMid.add(p);
                else noMid.add(p);
            }

            Map<String, Id> customerIdToAccountId = getMatchingAccounts(withMid);
            Map<String, Id> externalIdToLeadId    = createNewLeads(noMid, fsReqId);

            // Assemble EPs
            for (DAPV1AttendanceRequest.ParticipantPayload p : newCandidates) {
                Id saId = payloadToSa.get(p);
                if (saId == null) continue;
                DAP_Event_Participant__c ep = new DAP_Event_Participant__c(
                    Service_Appointment__c = saId,
                    ExternalId__c          = p.externalId,
                    First_Name__c           = p.firstName,
                    Last_Name__c            = p.lastName,
                    Notification_Email__c  = p.email,
                    Notification_Phone__c  = p.phone,
                    Status__c              = normalizeStatus(p.status),
                    Meeting_Method__c      = 'Virtual'
                );
                if (String.isNotBlank(p.id) && customerIdToAccountId.containsKey(p.id)) {
                    ep.Account__c = customerIdToAccountId.get(p.id);
                } else if (externalIdToLeadId.containsKey(p.externalId)) {
                    ep.Lead__c = externalIdToLeadId.get(p.externalId);
                }
                toInsert.add(ep);
            }
        }

        // --- Step 6: Bulk DML ---
        if (!toInsert.isEmpty())  DAPV1ParticipantDmlAccessor.insertParticipants(toInsert);
        if (!toUpdate.isEmpty())  DAPV1ParticipantDmlAccessor.updateParticipants(toUpdate);

        // --- Step 7: Finalize SA statuses for those completed in this bin ---
        if (bin.finalizeSaIds != null && !bin.finalizeSaIds.isEmpty()) {
            Set<Id> finalizeValid = new Set<Id>();
            for (Id f : bin.finalizeSaIds) if (validSaIds.contains(f)) finalizeValid.add(f);
            if (!finalizeValid.isEmpty()) finalizeAppointmentStatuses(finalizeValid);
        }
    }

    /* ===== Helpers ===== */

    private Set<Id> validateServiceAppointments(Set<Id> saIds, String fsReqId) {
        Set<Id> valid = new Set<Id>();
        if (saIds == null || saIds.isEmpty()) return valid;
        Map<Id, ServiceAppointment> found = new Map<Id, ServiceAppointment>(
            [SELECT Id FROM ServiceAppointment WHERE Id IN :saIds]
        );
        for (Id saId : saIds) {
            if (found.containsKey(saId)) valid.add(saId);
            else DAPV1SchedulerApiLoggingUtil.logError(
                'Invalid Service Appointment ID provided in payload: ' + saId, fsReqId, DAPV1ParticipantSyncHandler.class);
        }
        return valid;
    }

    private Map<String, DAP_Event_Participant__c> getExistingParticipants(
        Map<Id, List<DAPV1AttendanceRequest.ParticipantPayload>> bySa
    ){
        Set<String> extIds = new Set<String>();
        for (Id saId : bySa.keySet()) {
            for (DAPV1AttendanceRequest.ParticipantPayload p : bySa.get(saId)) {
                if (String.isNotBlank(p.externalId)) extIds.add(p.externalId);
            }
        }
        Map<String, DAP_Event_Participant__c> out = new Map<String, DAP_Event_Participant__c>();
        if (extIds.isEmpty()) return out;

        for (DAP_Event_Participant__c ep : [
            SELECT Id, ExternalId__c, Status__c, Service_Appointment__c
            FROM DAP_Event_Participant__c
            WHERE Service_Appointment__c IN :bySa.keySet()
              AND ExternalId__c IN :extIds
        ]) {
            out.put(String.valueOf(ep.Service_Appointment__c) + '-' + ep.ExternalId__c, ep);
        }
        return out;
    }

    private void finalizeAppointmentStatuses(Set<Id> saIds) {
        List<ServiceAppointment> toUpd = [
            SELECT Id, Status FROM ServiceAppointment WHERE Id IN :saIds FOR UPDATE
        ];
        for (ServiceAppointment sa : toUpd) {
            if (sa.Status != 'Published with Registrations') {
                sa.Status = 'Published with Registrations';
            }
        }
        //if (!toUpd.isEmpty()) apptAccessor.updateServiceAppointments(toUpd);
    }

    private Map<String, Id> getMatchingAccounts(List<DAPV1AttendanceRequest.ParticipantPayload> participants) {
        if (participants == null || participants.isEmpty()) return new Map<String, Id>();
        List<Customer> customers = new List<Customer>();
        for (DAPV1AttendanceRequest.ParticipantPayload p : participants) {
            Customer c = new Customer();
            c.custType     = DAPV1SchedulerConstants.CUSTOMER;
            c.custId       = p.id;
            c.firstName    = p.firstName;
            c.lastName     = p.lastName;
            c.primaryEmail = p.email;
            customers.add(c);
        }
        Customers container = new Customers(customers);
        return accountsService.resolveAccountIds(container); // returns Map<MID, AccountId>
    }

    private Map<String, Id> createNewLeads(List<DAPV1AttendanceRequest.ParticipantPayload> participants, String fsReqId) {
        Map<String, Id> extIdToLeadId = new Map<String, Id>();
        if (participants == null || participants.isEmpty()) return extIdToLeadId;

        List<Lead> leads = new List<Lead>();
        Map<Integer, String> rowToExternalId = new Map<Integer, String>();

        Integer idx = 0;
        for (DAPV1AttendanceRequest.ParticipantPayload p : participants) {
            Lead l = new Lead(
                FirstName = p.firstName,
                LastName  = p.lastName,
                Email     = p.email,
                Phone     = p.phone
            );
            leads.add(l);
            rowToExternalId.put(idx++, p.externalId);
        }

        Database.SaveResult[] sr = Database.insert(leads, false);
        for (Integer i = 0; i < sr.size(); i++) {
            if (sr[i].isSuccess()) {
                String ext = rowToExternalId.get(i);
                if (String.isNotBlank(ext)) extIdToLeadId.put(ext, sr[i].getId());
            } else {
                Database.Error err = sr[i].getErrors().isEmpty() ? null : sr[i].getErrors()[0];
                DAPV1SchedulerApiLoggingUtil.logError(
                    'Failed to create Lead for externalId: ' + rowToExternalId.get(i) + 
                    (err != null ? ('. Error: ' + err.getMessage()) : ''),
                    fsReqId, DAPV1ParticipantSyncHandler.class
                );
            }
        }
        return extIdToLeadId;
    }

    private String normalizeStatus(String status) { 
        if (String.isBlank(status)) return 'Registered';
        String s = status.toLowerCase().trim();
        if (s == 'attended') return 'Attended';
        if (s == 'no show' || s == 'no_show') return 'No Show';
        return 'Registered';
    }
}



public with sharing class DAPV1ParticipantDmlAccessor {

    public static void insertParticipants(List<DAP_Event_Participant__c> participants) {
        if (participants == null || participants.isEmpty()) return;
        try {
            Database.SaveResult[] sr = Database.insert(participants, /* allOrNone */ false);
            logErrors(sr, participants);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'Unexpected error during participant insert: ' + e.getMessage());
        }
    }

    public static void updateParticipants(List<DAP_Event_Participant__c> participants) {
        if (participants == null || participants.isEmpty()) return;
        try {
            Database.SaveResult[] sr = Database.update(participants, /* allOrNone */ false);
            logErrors(sr, participants);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'Unexpected error during participant update: ' + e.getMessage());
        }
    }

    private static void logErrors(Database.SaveResult[] results,
                                  List<DAP_Event_Participant__c> records) {
        if (results == null) return;
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                Database.Error err = results[i].getErrors().isEmpty()
                    ? null : results[i].getErrors()[0];
                DAP_Event_Participant__c rec = (i < records.size()) ? records[i] : null;
                System.debug(LoggingLevel.ERROR,
                    'Failed to process participant. ' +
                    'ExternalId=' + (rec != null ? rec.ExternalId__c : 'UNKNOWN') +
                    ' StatusCode=' + (err != null ? String.valueOf(err.getStatusCode()) : 'n/a') +
                    ' Message=' + (err != null ? err.getMessage() : 'n/a'));
            }
        }
    }
}

public with sharing class DAPV1ParticipantBinRepository {
    private static final String STATUS_QUEUED     = 'Queued';
    private static final String STATUS_PROCESSING = 'Processing';
    private static final String STATUS_COMPLETED  = 'Completed';
    private static final String STATUS_FAILED     = 'Failed';

    // Insert one row per bin; returns the created record Ids.
    public static List<Id> insertBins(String runId, List<DAPV1ParticipantBinPayload> bins) {
        if (String.isBlank(runId) || bins == null || bins.isEmpty()) return new List<Id>();

        List<DAP_Participant_Bin__c> rows = new List<DAP_Participant_Bin__c>();
        Integer seq = 1;
        for (DAPV1ParticipantBinPayload bin : bins) {
            // Serialize the bin to Long Text (<=32k). We keep it lean by default serialization.
            String json = JSON.serialize(bin);
            rows.add(new DAP_Participant_Bin__c(
                Run_Id__c            = runId,
                Sequence_Number__c   = seq++,
                Status__c            = STATUS_QUEUED,
                Participant_Bin__c   = json
            ));
        }
        Database.SaveResult[] sr = Database.insert(rows, false);

        List<Id> out = new List<Id>();
        for (Database.SaveResult r : sr) if (r.isSuccess()) out.add(r.getId());
        return out;
    }

    // Find the next queued bin for a run and lock it (no ORDER BY + FOR UPDATE).
    // Returns null if no queued bin remains.
    public static DAP_Participant_Bin__c lockNextQueuedBin(String runId) {
        if (String.isBlank(runId)) return null;

        // Step 1: compute MIN(sequence) among queued bins (no lock).
        AggregateResult[] ar = [
            SELECT MIN(Sequence_Number__c) minSeq
            FROM DAP_Participant_Bin__c
            WHERE Run_Id__c = :runId AND Status__c = :STATUS_QUEUED
            GROUP BY Run_Id__c
            LIMIT 1
        ];
        if (ar.isEmpty() || ar[0].get('minSeq') == null) return null;

        Integer nextSeq = (Integer) ar[0].get('minSeq');

        // Step 2: lock the specific record at that sequence.
        List<DAP_Participant_Bin__c> rows = [
            SELECT Id, Run_Id__c, Sequence_Number__c, Status__c, Job_Id__c
            FROM DAP_Participant_Bin__c
            WHERE Run_Id__c = :runId
              AND Status__c = :STATUS_QUEUED
              AND Sequence_Number__c = :nextSeq
            LIMIT 1 FOR UPDATE
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    public static void markProcessing(Id binId, String jobId) {
        if (binId == null) return;
        DAP_Participant_Bin__c row = new DAP_Participant_Bin__c(
            Id = binId,
            Status__c = STATUS_PROCESSING,
            Job_Id__c = jobId
        );
        update row;
    }

    public static void markCompleted(Id binId) {
        if (binId == null) return;
        update new DAP_Participant_Bin__c(Id = binId, Status__c = STATUS_COMPLETED);
    }

    public static void markFailed(Id binId) {
        if (binId == null) return;
        update new DAP_Participant_Bin__c(Id = binId, Status__c = STATUS_FAILED);
    }

    // Fetches the full bin JSON (no lock needed in processor).
    public static DAP_Participant_Bin__c getBin(Id binId) {
        if (binId == null) return null;
        List<DAP_Participant_Bin__c> rows = [
            SELECT Id, Run_Id__c, Sequence_Number__c, Status__c, Job_Id__c, Participant_Bin__c
            FROM DAP_Participant_Bin__c
            WHERE Id = :binId
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }
}

public with sharing class DAPV1ParticipantBinDispatchQueueable implements Queueable {
    private final String runId;
    private final String fsReqId;

    public DAPV1ParticipantBinDispatchQueueable(String runId, String fsReqId) {
        this.runId  = runId;
        this.fsReqId = fsReqId;
    }

    public void execute(QueueableContext ctx) {
        try {
            DAP_Participant_Bin__c nextBin = DAPV1ParticipantBinRepository.lockNextQueuedBin(runId);
            if (nextBin == null) {
                DAPV1SchedulerApiLoggingUtil.logInfo(
                    '[BinDispatch] No queued bins for runId=' + runId,
                    fsReqId, DAPV1ParticipantBinDispatchQueueable.class
                );
                return;
            }

            // Enqueue the processor for THIS bin (one job)
            String jobId = System.enqueueJob(
                new DAPV1ParticipantBinProcessorQueueable(nextBin.Id, runId, fsReqId)
            );

            // Mark the bin as Processing and store job id
            DAPV1ParticipantBinRepository.markProcessing(nextBin.Id, jobId);

            DAPV1SchedulerApiLoggingUtil.logInfo(
                '[BinDispatch] Dispatched bin seq=' + nextBin.Sequence_Number__c + ' jobId=' + jobId,
                fsReqId, DAPV1ParticipantBinDispatchQueueable.class
            );
        } catch (Exception e) {
            DAPV1SchedulerApiLoggingUtil.logError(
                '[BinDispatch] Error: ' + e.getMessage(),
                fsReqId, DAPV1ParticipantBinDispatchQueueable.class
            );
        }
    }
}

