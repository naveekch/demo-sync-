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
            String masterRunId = EncodingUtil.convertToHex(Crypto.generateAesKey(128)); 

            // 5) Global pack → fewest bins, track per-bin finalizeSaIds
            List<DAPV1ParticipantBinPayload> bins = packIntoBins(body.appointments);

            // 6) Enqueue one job per bin
            DAPV1ParticipantBinRepository.insertBins(masterRunId, bins);
            System.enqueueJob(new DAPV1ParticipantBinDispatchQueueable(masterRunId, fsReqId));

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
        String runKey = null;
        try {
            DAP_Participant_Bin__c binRow = DAPV1ParticipantBinRepository.getBin(binRecordId);
    
            // Capture runKey safely (binRow may be null)
            runKey = (binRow != null) ? binRow.Run_Id__c : null;
    
            if (binRow == null || String.isBlank(binRow.Participant_Bin__c)) {
                DAPV1SchedulerApiLoggingUtil.logError(
                    '[BinProcessor] Missing bin row or JSON for binId=' + binRecordId,
                    fsReqId, DAPV1ParticipantBinProcessorQueueable.class
                );
                DAPV1ParticipantBinRepository.markFailed(binRecordId);
    
                // Dispatch next bin even on this failure branch
                if (runKey != null) {
                    DAPV1ParticipantBinFutureDispatcher.dispatchNext(runKey, fsReqId);
                }
                return;
            }
    
            DAPV1ParticipantBinPayload bin =
                (DAPV1ParticipantBinPayload) JSON.deserialize(
                    binRow.Participant_Bin__c, DAPV1ParticipantBinPayload.class
                );
    
            // Process the bin (runId can be null; handler doesn’t use it functionally)
            new DAPV1ParticipantSyncHandler().processBin(bin, runId, fsReqId);
    
            // Mark completed
            DAPV1ParticipantBinRepository.markCompleted(binRecordId);
    
            // Kick off the next bin (separate async txn)
            if (runKey != null) {
                DAPV1ParticipantBinFutureDispatcher.dispatchNext(runKey, fsReqId);
            }
    
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
            // Still dispatch the next bin so the run can continue
            if (runKey != null) {
                DAPV1ParticipantBinFutureDispatcher.dispatchNext(runKey, fsReqId);
            }
        }
    }
}

public with sharing class DAPV1ParticipantSyncHandler {

    // Still used for MID->Account resolution
    @TestVisible private AccountsService accountsService = new AccountsService();

    /**
     * Processes one packed bin of participants in a single synchronous transaction.
     * - Validates SAs and fetches their meeting methods (VLE__c)
     * - Dedupes by SA+ExternalId, updates status for existing EPs
     * - Resolves Account by MID or creates Leads when no MID
     * - Inserts new EPs with proper Meeting Method
     * - Finalizes SA statuses for SAs completed in this bin
     */
    public void processBin(DAPV1ParticipantBinPayload bin, Id runId, String fsReqId) {
        // --- Step 1: Gather participants per SA (Id-keyed)
        Map<Id, List<DAPV1AttendanceRequest.ParticipantPayload>> bySa =
            new Map<Id, List<DAPV1AttendanceRequest.ParticipantPayload>>();
        if (bin == null || bin.slices == null || bin.slices.isEmpty()) return;

        for (DAPV1ParticipantBinPayload.ApptSlice slice : bin.slices) {
            if (slice == null || slice.serviceAppointmentId == null ||
                slice.participants == null || slice.participants.isEmpty()) {
                continue;
            }
            if (!bySa.containsKey(slice.serviceAppointmentId)) {
                bySa.put(slice.serviceAppointmentId, new List<DAPV1AttendanceRequest.ParticipantPayload>());
            }
            bySa.get(slice.serviceAppointmentId).addAll(slice.participants);
        }
        if (bySa.isEmpty()) return;

        // --- Step 2: Validate SAs and get meeting methods (VLE__c)
        Map<Id, String> meetingMethodBySaId =
            DAPV1ParticipantDmlAccessor.validateAndGetSaMeetingMethods(bySa.keySet(), fsReqId);

        Set<Id> validSaIds = new Set<Id>(meetingMethodBySaId.keySet());
        if (validSaIds.isEmpty()) {
            DAPV1SchedulerApiLoggingUtil.logError(
                'No valid Service Appointments found in this bin.',
                fsReqId,
                DAPV1ParticipantSyncHandler.class
            );
            return;
        }

        // --- Step 3: Dedup query (existing EPs by SA+ExternalId)
        Map<String, DAP_Event_Participant__c> existing =
            DAPV1ParticipantDmlAccessor.fetchExistingParticipants(bySa);

        // --- Step 4: Triage into updates vs inserts
        List<DAP_Event_Participant__c> toUpdate = new List<DAP_Event_Participant__c>();
        List<DAPV1AttendanceRequest.ParticipantPayload> newCandidates = new List<DAPV1AttendanceRequest.ParticipantPayload>();
        Map<DAPV1AttendanceRequest.ParticipantPayload, Id> payloadToSa = new Map<DAPV1AttendanceRequest.ParticipantPayload, Id>();

        for (Id saId : bySa.keySet()) {
            if (!validSaIds.contains(saId)) continue;

            for (DAPV1AttendanceRequest.ParticipantPayload p : bySa.get(saId)) {
                payloadToSa.put(p, saId);
                String key = String.valueOf(saId) + '-' + p.externalId;

                if (existing.containsKey(key)) {
                    // Update only status for existing EP
                    DAP_Event_Participant__c ep = existing.get(key);
                    ep.Status__c = normalizeStatus(p.status);
                    toUpdate.add(ep);
                } else {
                    newCandidates.add(p);
                }
            }
        }

        // --- Step 5: Insert path (resolve Account by MID; else create Lead)
        List<DAP_Event_Participant__c> toInsert = new List<DAP_Event_Participant__c>();
        if (!newCandidates.isEmpty()) {
            // Split by MID vs no-MID
            List<DAPV1AttendanceRequest.ParticipantPayload> withMid = new List<DAPV1AttendanceRequest.ParticipantPayload>();
            List<DAPV1AttendanceRequest.ParticipantPayload> noMid   = new List<DAPV1AttendanceRequest.ParticipantPayload>();
            for (DAPV1AttendanceRequest.ParticipantPayload p : newCandidates) {
                if ('mid'.equalsIgnoreCase(p.customerIdtype) && String.isNotBlank(p.id)) {
                    withMid.add(p);
                } else {
                    noMid.add(p);
                }
            }

            // Resolve accounts for MIDs
            Map<String, Id> customerIdToAccountId = new Map<String, Id>();
            if (!withMid.isEmpty()) {
                List<Customer> customers = new List<Customer>();
                for (DAPV1AttendanceRequest.ParticipantPayload p : withMid) {
                    Customer c = new Customer();
                    c.custType     = DAPV1SchedulerConstants.CUSTOMER;
                    c.custId       = p.id;
                    c.firstName    = p.firstName;
                    c.lastName     = p.lastName;
                    c.primaryEmail = p.email;
                    customers.add(c);
                }
                Customers container = new Customers(customers);
                customerIdToAccountId = accountsService.resolveAccountIds(container); // Map<MID, AccountId>
            }

            // Create Leads for no-MID
            Map<String, Id> externalIdToLeadId = DAPV1ParticipantDmlAccessor.createNewLeads(noMid, fsReqId);

            // Build EP inserts
            for (DAPV1AttendanceRequest.ParticipantPayload p : newCandidates) {
                Id saId = payloadToSa.get(p);
                if (saId == null) continue;

                // Meeting method for this SA
                String meetingMethod = meetingMethodBySaId.get(saId);
                if (String.isBlank(meetingMethod)) meetingMethod = 'Virtual';

                DAP_Event_Participant__c ep = new DAP_Event_Participant__c(
                    Service_Appointment__c = saId,
                    ExternalId__c          = p.externalId,
                    First_Name__c          = p.firstName,
                    Last_Name__c           = p.lastName,
                    Notification_Email__c  = p.email,
                    Notification_Phone__c  = p.phone,
                    Status__c              = normalizeStatus(p.status),
                    Meeting_Method__c      = meetingMethod
                );

                // Link Account (via MID) or Lead (no MID)
                if (String.isNotBlank(p.id) && customerIdToAccountId.containsKey(p.id)) {
                    ep.Account__c = customerIdToAccountId.get(p.id);
                } else if (externalIdToLeadId.containsKey(p.externalId)) {
                    ep.Lead__c = externalIdToLeadId.get(p.externalId);
                }

                toInsert.add(ep);
            }
        }

        // --- Step 6: Bulk DML (partial success allowed)
        if (!toInsert.isEmpty())  DAPV1ParticipantDmlAccessor.insertParticipants(toInsert);
        if (!toUpdate.isEmpty())  DAPV1ParticipantDmlAccessor.updateParticipants(toUpdate);

        // --- Step 7: Finalize SA statuses for those completed in this bin
        if (bin.finalizeSaIds != null && !bin.finalizeSaIds.isEmpty()) {
            Set<Id> finalizeValid = new Set<Id>();
            for (Id f : bin.finalizeSaIds) if (validSaIds.contains(f)) finalizeValid.add(f);
            if (!finalizeValid.isEmpty()) {
                DAPV1ParticipantDmlAccessor.finalizeAppointmentStatuses(finalizeValid);
            }
        }
    }

    /* ===== Helpers ===== */

    private String normalizeStatus(String status) {
        if (String.isBlank(status)) return 'Registered';
        String s = status.toLowerCase().trim();
        if (s == 'attended') return 'Attended';
        if (s == 'no show' || s == 'no_show') return 'No Show';
        return 'Registered';
    }
}



public with sharing class DAPV1ParticipantDmlAccessor {

    /* =========================
       Participant DML (partial)
       ========================= */

    public static void insertParticipants(List<DAP_Event_Participant__c> participants) {
        if (participants == null || participants.isEmpty()) return;
        try {
            Database.SaveResult[] sr = Database.insert(participants, /* allOrNone */ false);
        } catch (Exception e) {
            DAPV1SchedulerApiLoggingUtil.logError(
                'insertParticipants: unexpected error: ' + e.getMessage(),
                null,
                DAPV1ParticipantDmlAccessor.class
            );
        }
    }

    public static void updateParticipants(List<DAP_Event_Participant__c> participants) {
        if (participants == null || participants.isEmpty()) return;
        try {
            Database.SaveResult[] sr = Database.update(participants, /* allOrNone */ false);
        } catch (Exception e) {
            DAPV1SchedulerApiLoggingUtil.logError(
                'updateParticipants: unexpected error: ' + e.getMessage(),
                null,
                DAPV1ParticipantDmlAccessor.class
            );
        }
    }

    

    /* ==============================================
       SA validation + meeting method (VLE__c) fetch
       ============================================== */

    // Returns SA Id -> meeting method (VLE__c). Logs invalid SA ids.
    public static Map<Id, String> validateAndGetSaMeetingMethods(Set<Id> saIds, String fsReqId) {
        Map<Id, String> meetingMethodBySaId = new Map<Id, String>();
        if (saIds == null || saIds.isEmpty()) return meetingMethodBySaId;

        try {
            for (ServiceAppointment sa : [
                SELECT Id, VLE__c
                FROM ServiceAppointment
                WHERE Id IN :saIds
            ]) {
                meetingMethodBySaId.put(sa.Id, sa.VLE__c);
            }
        } catch (Exception e) {
            DAPV1SchedulerApiLoggingUtil.logError(
                'validateAndGetSaMeetingMethods: query failed. Err=' + e.getMessage(),
                fsReqId,
                DAPV1ParticipantDmlAccessor.class
            );
            return meetingMethodBySaId;
        }

        // Log any IDs not found
        Set<Id> invalid = new Set<Id>(saIds);
        invalid.removeAll(meetingMethodBySaId.keySet());
        for (Id bad : invalid) {
            DAPV1SchedulerApiLoggingUtil.logError(
                'Invalid Service Appointment ID provided in payload: ' + bad,
                fsReqId,
                DAPV1ParticipantDmlAccessor.class
            );
        }
        return meetingMethodBySaId;
    }

    /* =========================================
       Existing EP fetch for SA+ExternalId dedupe
       ========================================= */

    public static Map<String, DAP_Event_Participant__c> fetchExistingParticipants(
        Map<Id, List<DAPV1AttendanceRequest.ParticipantPayload>> bySa
    ){
        Map<String, DAP_Event_Participant__c> existingBySaExtKey = new Map<String, DAP_Event_Participant__c>();
        if (bySa == null || bySa.isEmpty()) return existingBySaExtKey;

        // Collect external ids present in payload
        Set<String> extIds = new Set<String>();
        for (Id saId : bySa.keySet()) {
            for (DAPV1AttendanceRequest.ParticipantPayload p : bySa.get(saId)) {
                if (String.isNotBlank(p.externalId)) extIds.add(p.externalId);
            }
        }
        if (extIds.isEmpty()) return existingBySaExtKey;

        try {
            for (DAP_Event_Participant__c ep : [
                SELECT Id, ExternalId__c, Status__c, Service_Appointment__c
                FROM DAP_Event_Participant__c
                WHERE Service_Appointment__c IN :bySa.keySet()
                  AND ExternalId__c IN :extIds
            ]) {
                existingBySaExtKey.put(
                    String.valueOf(ep.Service_Appointment__c) + '-' + ep.ExternalId__c,
                    ep
                );
            }
        } catch (Exception e) {
            DAPV1SchedulerApiLoggingUtil.logError(
                'fetchExistingParticipants failed: ' + e.getMessage(),
                null,
                DAPV1ParticipantDmlAccessor.class
            );
        }
        return existingBySaExtKey;
    }

    /* ==========================
       Lead creation for no-MID
       ========================== */

    // Creates Leads for participants without MID; returns ExternalId -> LeadId
    public static Map<String, Id> createNewLeads(
        List<DAPV1AttendanceRequest.ParticipantPayload> participants,
        String fsReqId
    ) {
        Map<String, Id> extIdToLeadId = new Map<String, Id>();
        if (participants == null || participants.isEmpty()) return extIdToLeadId;

        List<Lead> leads = new List<Lead>();
        Map<Integer, String> rowToExternalId = new Map<Integer, String>();
        Integer idx = 0;

        for (DAPV1AttendanceRequest.ParticipantPayload p : participants) {
            leads.add(new Lead(
                FirstName = p.firstName,
                LastName  = p.lastName,
                Email     = p.email,
                Phone     = p.phone
            ));
            rowToExternalId.put(idx++, p.externalId);
        }

        try {
            Database.SaveResult[] sr = Database.insert(leads, /* allOrNone */ false);
            for (Integer i = 0; i < sr.size(); i++) {
                if (sr[i].isSuccess()) {
                    String ext = rowToExternalId.get(i);
                    if (String.isNotBlank(ext)) extIdToLeadId.put(ext, sr[i].getId());
                } else {
                    Database.Error err = sr[i].getErrors().isEmpty() ? null : sr[i].getErrors()[0];
                    DAPV1SchedulerApiLoggingUtil.logError(
                        'createNewLeads: failed for externalId=' + rowToExternalId.get(i) +
                        (err != null ? ('. Error: ' + err.getMessage()) : ''),
                        fsReqId,
                        DAPV1ParticipantDmlAccessor.class
                    );
                }
            }
        } catch (Exception e) {
            DAPV1SchedulerApiLoggingUtil.logError(
                'createNewLeads: unexpected error: ' + e.getMessage(),
                fsReqId,
                DAPV1ParticipantDmlAccessor.class
            );
        }
        return extIdToLeadId;
    }

    /* ============================================
       Finalize SA status (FOR UPDATE, no ORDER BY)
       ============================================ */

    public static void finalizeAppointmentStatuses(Set<Id> saIds) {
        if (saIds == null || saIds.isEmpty()) return;

        try {
            List<ServiceAppointment> toUpd = [
                SELECT Id, Status
                FROM ServiceAppointment
                WHERE Id IN :saIds
                FOR UPDATE
            ];
            for (ServiceAppointment sa : toUpd) {
                if (sa.Status != 'Published with Registrations') {
                    sa.Status = 'Published with Registrations';
                }
            }
            if (!toUpd.isEmpty()) {
                update toUpd;
            }
        } catch (Exception e) {
            DAPV1SchedulerApiLoggingUtil.logError(
                'finalizeAppointmentStatuses: update failed. Err=' + e.getMessage(),
                null,
                DAPV1ParticipantDmlAccessor.class
            );
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

    // 1) Get the smallest sequence among queued bins (aggregate returns Decimal)
    AggregateResult[] ar = [
        SELECT MIN(Sequence_Number__c) minSeq
        FROM DAP_Participant_Bin__c
        WHERE Run_Id__c = :runId AND Status__c = :STATUS_QUEUED
        GROUP BY Run_Id__c
        LIMIT 1
    ];
    if (ar.isEmpty() || ar[0].get('minSeq') == null) return null;

    Decimal nextSeqDec = (Decimal) ar[0].get('minSeq');
    Integer nextSeq = nextSeqDec.intValue();

    // 2) Lock that specific row
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
                new DAPV1ParticipantBinProcessorQueueable(nextBin.Id, null, fsReqId)
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

public with sharing class DAPV1ParticipantBinFutureDispatcher {
    @future
    public static void dispatchNext(String runId, String fsReqId) {
        System.enqueueJob(new DAPV1ParticipantBinDispatchQueueable(runId, fsReqId));
    }
}

