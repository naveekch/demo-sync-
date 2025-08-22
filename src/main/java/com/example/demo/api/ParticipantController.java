package com.example.demo.api;

import com.example.demo.service.ParticipantService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/appointments/participants")
public class ParticipantController {
    private final ParticipantService svc;
    public ParticipantController(ParticipantService svc){ this.svc = svc; }

    @PostMapping
    public ResponseEntity<Void> upsertBatch(@RequestBody BatchRequest request) {
        boolean createdAny = svc.upsertBatch(request);
        return createdAny
                ? ResponseEntity.status(201).build()
                : ResponseEntity.noContent().build(); // 204
    }
}