/**
 * This is the main entrypoint for the bulk attendance API.
 * It's designed to be a fast, synchronous "hand-off". It takes the big payload,
 * uses a "bin packing" algorithm to break it into safe chunks, and then enqueues
 * a separate job for each chunk.
 */
@RestResource(urlMapping='/scheduler/v1/attendance')
global with sharing class DAPV1AttendanceResource {

    // The max number of participants we'll stuff into a single background job.
    // We keep this well under the limits to stay safe.
    @TestVisible private static final Integer BIN_CAPACITY = 500;

    @HttpPost
    global static void processAttendance() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        System.debug(LoggingLevel.INFO, '[AttendanceAPI] Request received.');

        try {
            // 1. Turn the incoming JSON into our Apex request object.
            DAPV1AttendanceRequest requestBody = (DAPV1AttendanceRequest) JSON.deserialize(
                req.requestBody.toString(),
                DAPV1AttendanceRequest.class
            );

            // 2. Quick sanity check on the payload.
            if (requestBody == null || requestBody.appointments == null || requestBody.appointments.isEmpty()) {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf('{"error": "The \'appointments\' list cannot be null or empty."}');
                return;
            }
            System.debug(LoggingLevel.INFO, '[AttendanceAPI] Deserialization successful. Found ' + requestBody.appointments.size() + ' appointments.');

            // 3. This is the "bin packing" step. We group the appointments into
            //    a smaller number of manageable jobs ("bins").
            List<List<DAPV1AttendanceRequest.AppointmentPayload>> bins = packIntoBins(requestBody.appointments);
            System.debug(LoggingLevel.INFO, '[AttendanceAPI] Bin packing complete. Created ' + bins.size() + ' bins.');

            // 4. Kick off one background job for each bin. This is the "fan-out".
            for (List<DAPV1AttendanceRequest.AppointmentPayload> bin : bins) {
                if (!bin.isEmpty()) {
                    // Start the chain at the beginning of the bin (appointmentIndex=0, participantIndex=0)
                    System.enqueueJob(new DAPV1ParticipantBinProcessorQueueable(bin, 0, 0));
                }
            }

            // 5. Instantly tell the client "we got it". The actual work happens in the background.
            //    The 202 "Accepted" status is the standard way to do this.
            res.statusCode = 202;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, String>{
                'status' => 'Request accepted for processing.',
                'jobId' => 'Multiple jobs enqueued (' + bins.size() + ' bins created)'
            }));

        } catch (Exception e) {
            // If anything goes wrong here (like bad JSON), we send a 500.
            System.debug(LoggingLevel.ERROR, '[AttendanceAPI] Critical error: ' + e.getMessage() + ' Stacktrace: ' + e.getStackTraceString());
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"error": "' + e.getMessage() + '"}');
        }
        System.debug(LoggingLevel.INFO, '[AttendanceAPI] Request finished.');
    }

    /**
     * This is our "bin packing" logic. It takes the big list of appointments
     * and groups them into smaller, safer chunks (bins) for processing. The main goals are:
     * 1. Keep any single job from getting too big (respects BIN_CAPACITY).
     * 2. Make sure the same appointment doesn't end up in two different jobs, which
     * would cause race conditions.
     */
    private static List<List<DAPV1AttendanceRequest.AppointmentPayload>> packIntoBins(List<DAPV1AttendanceRequest.AppointmentPayload> allAppointments) {
        List<List<DAPV1AttendanceRequest.AppointmentPayload>> bins = new List<List<DAPV1AttendanceRequest.AppointmentPayload>>();
        List<Integer> binCounts = new List<Integer>();
        Set<String> processedAppointmentIds = new Set<String>();

        for (DAPV1AttendanceRequest.AppointmentPayload appt : allAppointments) {
            // Basic safety checks for malformed data.
            if (appt == null || String.isBlank(appt.serviceAppointmentId)) continue;
            
            // This Set ensures that if the client sends the same appointment ID twice
            // in one payload, we only process it once. Prevents race conditions.
            if (processedAppointmentIds.contains(appt.serviceAppointmentId)) continue;

            Integer participantCount = (appt.participants != null) ? appt.participants.size() : 0;
            if (participantCount == 0) continue; // Don't create jobs for appointments with no one in them.

            Boolean placed = false;
            // Try to fit this appointment into any of the bins we've already created.
            for (Integer i = 0; i < bins.size(); i++) {
                if (binCounts[i] + participantCount <= BIN_CAPACITY) {
                    bins[i].add(appt);
                    binCounts[i] += participantCount;
                    placed = true;
                    break;
                }
            }

            // If it was too big for any existing bin, create a new one just for it.
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
// This just defines the structure of the data we expect from the client.
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
 * This is our main "smart worker" queueable. It's stateful, which means it keeps track
 * of where it is in the process using indexes (cursors).
 *
 * It will process one small chunk of work (a few participants for one appointment)
 * and then re-enqueue itself to handle the next chunk. This chaining is the key to
 * staying under governor limits and is the only legal way to enqueue a job from
 * an async context.
 */
public with sharing class DAPV1ParticipantBinProcessorQueueable implements Queueable {

    // How many participants we process in a single go. A smaller number is safer
    // and leaves more room for other automation in the org.
    @TestVisible private static final Integer MAX_PARTICIPANTS_PER_EXEC = 500;
    
    // --- Cursors that track our progress through the bin ---
    private final List<DAPV1AttendanceRequest.AppointmentPayload> appointmentsInBin;
    private final Integer appointmentIndex; // Which appointment in the bin we're on.
    private final Integer participantIndex; // Which participant in that appointment we're on.

    public DAPV1ParticipantBinProcessorQueueable(List<DAPV1AttendanceRequest.AppointmentPayload> appointmentsInBin, Integer appointmentIndex, Integer participantIndex) {
        this.appointmentsInBin = appointmentsInBin;
        this.appointmentIndex = appointmentIndex;
        this.participantIndex = participantIndex;
    }

    public void execute(QueueableContext context) {
        // If we've processed all appointments in our bin, we're done.
        if (appointmentIndex >= appointmentsInBin.size()) {
            System.debug(LoggingLevel.INFO, '[BinProcessor] Bin complete. No more appointments.');
            return;
        }

        DAPV1AttendanceRequest.AppointmentPayload currentAppointment = appointmentsInBin[appointmentIndex];
        
        // Safety check for empty/malformed appointment data.
        if (currentAppointment == null || currentAppointment.participants == null || currentAppointment.participants.isEmpty()) {
            Integer nextAppt = appointmentIndex + 1;
            // Skip to the next appointment in the bin if there is one.
            if (nextAppt < appointmentsInBin.size()) {
                 System.enqueueJob(new DAPV1ParticipantBinProcessorQueueable(appointmentsInBin, nextAppt, 0));
            }
            return;
        }
        List<DAPV1AttendanceRequest.ParticipantPayload> participants = currentAppointment.participants;
        
        // This is the "slicing" part. We only take a small, safe-sized chunk from
        // the main participant list to work on in this transaction.
        Integer startIndex = participantIndex;
        Integer endIndex = Math.min(participants.size(), startIndex + MAX_PARTICIPANTS_PER_EXEC);
        List<DAPV1AttendanceRequest.ParticipantPayload> chunkToProcess = participants.subList(startIndex, endIndex);

        System.debug(LoggingLevel.INFO, '[BinProcessor] Processing chunk for SA ID: ' + currentAppointment.serviceAppointmentId + 
            '. Participants ' + (startIndex + 1) + ' to ' + endIndex);

        // --- Do the actual work for the current chunk ---
        // We call a separate, synchronous handler to do the business logic.
        DAPV1ParticipantSyncHandler handler = new DAPV1ParticipantSyncHandler();
        handler.processChunk(currentAppointment.serviceAppointmentId, chunkToProcess);

        // --- Chaining Logic: Figure out what to do next ---
        Integer nextAppointmentIndex = appointmentIndex;
        Integer nextParticipantIndex = endIndex;

        // Have we finished all participants for the CURRENT appointment?
        if (nextParticipantIndex >= participants.size()) {
            // If yes, we can finalize its status. This is the only place this happens.
            System.debug(LoggingLevel.INFO, '[BinProcessor] Finished all participants for SA ID: ' + currentAppointment.serviceAppointmentId);
            
            // TODO: [POC] Re-enable parent Service Appointment status update for production.
            // This is commented out to keep the POC focused on data ingestion.
            // handler.finalizeAppointmentStatus(currentAppointment.serviceAppointmentId);
            
            // And then we move our cursor to the next appointment in the bin.
            nextAppointmentIndex++;
            nextParticipantIndex = 0;
        }

        // Is there any work left to do in our bin (either more participants or more appointments)?
        if (nextAppointmentIndex < appointmentsInBin.size()) {
            System.debug(LoggingLevel.INFO, '[BinProcessor] Chaining to next chunk. Next Appt Index: ' + nextAppointmentIndex + ', Next Part Index: ' + nextParticipantIndex);
            // If yes, enqueue the next job in the chain. This is the SINGLE enqueue allowed.
            System.enqueueJob(new DAPV1ParticipantBinProcessorQueueable(appointmentsInBin, nextAppointmentIndex, nextParticipantIndex));
        } else {
            System.debug(LoggingLevel.INFO, '[BinProcessor] All appointments in bin processed.');
        }
    }
}

/**
 * This is our "core engine". It's a simple, synchronous utility that does the
 * actual business logic for a single chunk of participants. It's designed to be
 * "dumb" - it just processes what it's given and has no async logic itself.
 * This keeps the logic clean and easy to test.
 */
public with sharing class DAPV1ParticipantSyncHandler {

    @TestVisible private DAPV1SObjSrvcApptDmlAccessor apptAccessor = new DAPV1SObjSrvcApptDmlAccessor();
    @TestVisible private DAPV1SObjEvntAudnceDmlAccessor eventAudienceDmlAccessor = new DAPV1SObjEvntAudnceDmlAccessor();

    public void processChunk(String serviceAppointmentId, List<DAPV1AttendanceRequest.ParticipantPayload> chunk) {
        
        // First, validate that the parent Service Appointment actually exists.
        ServiceAppointment parentAppointment = getServiceAppointment(serviceAppointmentId);
        if (parentAppointment == null) {
            // If the appointment doesn't exist, we can't process its participants.
            return;
        }

        if (chunk == null || chunk.isEmpty()) return;
        
        // This Map handles duplicates WITHIN the same chunk.
        Map<String, DAPV1AttendanceRequest.ParticipantPayload> dedupedParticipants = new Map<String, DAPV1AttendanceRequest.ParticipantPayload>();
        for (DAPV1AttendanceRequest.ParticipantPayload p : chunk) {
            if(String.isNotBlank(p.externalId)){
                dedupedParticipants.put(p.externalId, p);
            } else {
                System.debug(LoggingLevel.ERROR, '[SyncHandler] Participant skipped due to blank externalId. Email: ' + p.email);
            }
        }
        
        // Now we check this chunk against what's already in the database.
        Map<String, DAP_Event_Participant__c> existingParticipantsMap = getExistingParticipants(serviceAppointmentId, dedupedParticipants.values());

        List<DAP_Event_Participant__c> toInsert = new List<DAP_Event_Participant__c>();
        List<DAP_Event_Participant__c> toUpdate = new List<DAP_Event_Participant__c>();

        for (DAPV1AttendanceRequest.ParticipantPayload p : dedupedParticipants.values()) {
            String normalizedStatus = normalizeStatus(p.status);
            
            // For the POC, we only match by External ID.
            if (existingParticipantsMap.containsKey(p.externalId)) {
                // We found a match, so this is an update.
                DAP_Event_Participant__c existingParticipant = existingParticipantsMap.get(p.externalId);
                existingParticipant.Status__c = normalizedStatus;
                toUpdate.add(existingParticipant);
            } else {
                // No match found, so this is a new record.
                DAP_Event_Participant__c ep = new DAP_Event_Participant__c(
                    Service_Appointment__c = serviceAppointmentId,
                    ExternalId__c = p.externalId, 
                    CustomerIdType__c = p.customerIdtype,
                    Notification_Email__c = p.email,
                    Status__c = normalizedStatus,
                    Meeting_Method__c = 'Virtual'
                );

                /*
                // --- Production: Customer Matching & Lead Creation Logic (Future State) ---
                // This is where we would look up an Account by MID or create a new Lead.
                // For the POC, we are only creating the Event Participant record itself.
                
                // if (p.customerIdtype == 'mid') {
                //     ep.Account__c = findAccountIdByMid(p.externalId);
                // } else {
                //     ep.Lead__c = createNewLead(p);
                // }
                */
                toInsert.add(ep);
            }
        }
        
        // Hand off to the DML accessor to do the database work.
        DAPV1ParticipantDmlAccessor dmlAccessor = new DAPV1ParticipantDmlAccessor();
        if (!toInsert.isEmpty()) dmlAccessor.insertParticipants(toInsert);
        if (!toUpdate.isEmpty()) dmlAccessor.updateParticipants(toUpdate);
    }
    
    // This is the final step for an appointment. It's called by the queueable job
    // after all participants for a single SA have been processed.
    public void finalizeAppointmentStatus(String serviceAppointmentId){
        // We use FOR UPDATE here to put a lock on the SA record. This is a critical
        // step to prevent race conditions if two different API calls happen to
        // contain the same appointment ID.
        ServiceAppointment parentAppointment = [SELECT Id, Status FROM ServiceAppointment WHERE Id = :serviceAppointmentId FOR UPDATE];
        if(parentAppointment != null && parentAppointment.Status != 'Published with Registrations'){
            this.apptAccessor.updateTrgtSrvcApptStatus(parentAppointment, 'Published with Registrations');
        }
    }

    // Helper to make sure incoming status values match our picklist.
    private String normalizeStatus(String status) { 
        if (String.isBlank(status)) return 'Registered';
        String s = status.toLowerCase().trim();
        if (s == 'attended') return 'Attended';
        if (s == 'no show' || s == 'no_show') return 'No Show';
        return 'Registered';
     }
    // Helper to get the parent SA record.
    private ServiceAppointment getServiceAppointment(String appointmentId) { 
        try {
            // Re-using the existing accessor from the 1:1 flow.
            return this.eventAudienceDmlAccessor.getEventDetail(appointmentId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[SyncHandler] Service Appointment with ID ' + appointmentId + ' not found.');
            return null;
        }
     }
    
    // This is our simplified deduplication query for the POC. It only checks by ExternalId.
    private Map<String, DAP_Event_Participant__c> getExistingParticipants(String serviceAppointmentId, List<DAPV1AttendanceRequest.ParticipantPayload> participants) {
        Set<String> externalIds = new Set<String>();
        for(DAPV1AttendanceRequest.ParticipantPayload p : participants) {
            if (String.isNotBlank(p.externalId)) externalIds.add(p.externalId);
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
 * A simple utility for all our database operations (insert/update).
 * Keeps the DML logic separate and clean.
 */
public with sharing class DAPV1ParticipantDmlAccessor {

    public void insertParticipants(List<DAP_Event_Participant__c> participants) {
        System.debug(LoggingLevel.INFO, '[DMLAccessor] Attempting to insert ' + participants.size() + ' participant records.');
        try {
            // Using 'false' here allows for partial success. If one record in the
            // list fails, the others can still be inserted.
            Database.SaveResult[] saveResults = Database.insert(participants, false);
            logErrors(saveResults, participants);
        } catch (Exception e) {
             System.debug(LoggingLevel.ERROR, '[DMLAccessor] Unexpected error during participant insert: ' + e.getMessage());
        }
    }

    public void updateParticipants(List<DAP_Event_Participant__c> participants) {
        System.debug(LoggingLevel.INFO, '[DMLAccessor] Attempting to update ' + participants.size() + ' participant records.');
        try {
            Database.SaveResult[] saveResults = Database.update(participants, false);
            logErrors(saveResults, participants);
        } catch (Exception e) {
             System.debug(LoggingLevel.ERROR, '[DMLAccessor] Unexpected error during participant update: ' + e.getMessage());
        }
    }
    
    // Helper to loop through DML results and log any rows that failed to save.
    private void logErrors(Database.SaveResult[] results, List<DAP_Event_Participant__c> records) {
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                Database.Error error = results[i].getErrors()[0];
                DAP_Event_Participant__c failedRecord = records[i];
                System.debug(LoggingLevel.ERROR, '[DMLAccessor] Failed to process participant record. ' +
                    'ExternalId: ' + failedRecord.ExternalId__c + 
                    '. Error: ' + error.getStatusCode() + ' - ' + error.getMessage());
            }
        }
    }
}

