---
title: "Building a Multi-Service Enterprise AI Workshop on Huawei Cloud: A Serverless FunctionGraph Architecture"
description: "How we designed a serverless document-AI pipeline on Huawei Cloud (FunctionGraph, DMS, OCR, DeepSeek, Dify, DWS) for regulated financial workflows, and what we cut for the demo."
date: 2026-05-09
draft: false
tags: [huawei-cloud, serverless, functiongraph, enterprise-ai, fintech]
slug: serverless-enterprise-ai-workshop-functiongraph
featured: true
---

In April 2026, we prepared a Technology Innovation Workshop on **document-heavy compliance workflows in financial services**, delivered in Mexico City in May. The brief: show how Huawei Cloud could modernize compliance review, risk scoring, and regulatory reporting.

The architecture we designed goes well beyond what we ended up demoing in the room. This post covers the full design — the serverless **invoice and contract analysis pipeline** with **FunctionGraph**, **DMS/Kafka**, **OCR Service**, **DeepSeek**, and **Dify** — plus why we simplified it for a 45-minute workshop.

---

## The Problem

Compliance teams in financial services review **invoices, vendor profiles, and transaction anomalies** across thousands of entities, and much of that work is still manual:

- **Document review is slow**: OCR or retyping, validation against the ERP, legal review, then an ERP update, all for every document
- **Vendor onboarding takes days**, because each step waits on the previous one
- **No unified view**: PDFs in silos, vendor data in the ERP, credit-bureau data in separate systems

To size the design, we assumed **45,000 invoices per month (about 1,500 a day)**, each needing OCR extraction, validation against the ERP, and a compliance score. That is a sizing assumption, not a measured figure. The scaling math below uses it.

## The Full Architecture

The original design connects **nine components, almost all managed Huawei Cloud services**, into an asynchronous document-analysis pipeline:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  PIPELINE ASÍNCRONO (DMS/Kafka)                                         │
│                                                                         │
│  Upload PDF → OBS → FunctionGraph → OCR Service → DMS                   │
│                                                   ↓                     │
│                                          Parse Function                  │
│                                                   ↓                     │
│                                          DeepSeek (LLM Inference)        │
│                                            ├─ AI Summary                 │
│                                            ├─ Metadata                   │
│                                            └─ Doc Classification          │
│                                                   ↓                     │
│                                          OBS (results) + DWS            │
│                                                   ↓                     │
│                                          Dify Platform                   │
│                                            ├─ Embedding → KB             │
│                                            └─ AI Document Chatbot        │
└─────────────────────────────────────────────────────────────────────────┘
```

### Service Breakdown

| Service | Role |
|---------|------|
| **OBS** (Object Storage) | Raw invoice/contract storage, extracted text, results |
| **FunctionGraph** | Serverless orchestrator — triggers on OBS upload events |
| **OCR Service** | PDF/JPG → structured text extraction |
| **DMS** (Kafka-compatible) | Async event bus between pipeline stages |
| **FunctionGraph Parse Function** | Post-OCR normalization: tables, formatting, structure |
| **DeepSeek** (via MaaS) | LLM: AI Summary, Metadata, Doc Classification, Risk Clauses |
| **Dify Platform** | RAG knowledge base + AI Document Chatbot |
| **DWS** (Data Warehouse Service) | Structured storage of invoice risk scores and analytics |
| **CFW** (Cloud Firewall) | Perimeter security for regulated financial data |
| **KMS** (Key Management) | Encryption at rest for sensitive documents |

---

## Why FunctionGraph as the Orchestrator

The pipeline has **3 distinct processing phases**: OCR → Parse → LLM. Each phase has different resource requirements and latency profiles:

- **OCR**: CPU-bound, seconds per page
- **Parse**: Lightweight normalization, milliseconds
- **LLM Inference**: I/O-bound (API call), 3-15s per document

**FunctionGraph** is the natural choice because:

1. **Event-driven triggers** — An OBS PUT event fires the function. No polling, no VM sitting idle.
2. **Auto-scaling to zero** — Between batch uploads, there are zero running instances. At the volume we sized for (~1,500 invoices/day), the pipeline scales up during business hours, processes the batch, and releases resources.
3. **DMS integration** — The function writes results to DMS topics, which downstream consumers (Parse Function, DeepSeek, Dify) subscribe to independently. Each stage scales at its own rate.
4. **Cold start is manageable** — A ~1-3s cold start per function instance is invisible against 15s of LLM inference per document. Python runtimes warm faster; custom runtimes may vary.

> *Note on the diagram above: the "OCR Service" arrow from FunctionGraph represents a **synchronous call** within the same function invocation — not a separate function stage. The "Parse Function" is a second FunctionGraph instance triggered by the DMS topic. This distinction matters for timeout configuration and error handling.*

### The Trigger Chain

```
OBS PUT event
  └─→ FunctionGraph: "preprocess"
        ├─ OCR Service (synchronous call)
        └─ DMS topic: "ocr.completed"
              ├─ Parse Function (FunctionGraph, second function)
              │     └─ DMS topic: "parsed.documents"
              │           └─ DeepSeek LLM (via MaaS API)
              │                 └─ OBS (results) + DWS (structured)
              └─ Dify Platform (subscribes to both topics)
                    └─ Embedding → Knowledge Base
```

### Why DMS (Kafka) at This Volume

At this scale, an async event bus isn't optional — it's structural. Here's why:

1. **Pipeline stages have different scaling profiles** — OCR is CPU-bound and processes ~1 page/second per instance. LLM inference is I/O-bound and takes 3-15s per document. Without a buffer, a slow LLM call blocks OCR for subsequent invoices. DMS decouples them: the OCR stage writes results and returns immediately; downstream consumers (Parse + LLM) process at their own rate.

2. **Burst absorption** — Invoices arrive in waves (end-of-month peaks, supplier onboarding batches). DMS retains a backlog (72 hours in this design), so a 2x or 3x burst in document volume doesn't require over-provisioning compute.

3. **Audit requirements favor async** — Each DMS message carries metadata (document ID, source system, compliance tier). Topic replay provides a verifiable sequence of every document processed on any given day — a synchronous chain would require reconstructing from overlapping function logs.

4. **Individual stage scaling** — With DMS, each consumer group (Parse, LLM, Dify embedder) scales independently according to its own bottleneck. If LLM inference becomes the constraint (the likeliest scenario at this volume), we add more consumer instances to the `parsed.documents` topic without touching the OCR or embedding pipelines.

### Error Handling & Resilience

Each FunctionGraph invocation wraps its stage in try-catch logic. Failed documents land in a **DMS dead-letter queue** (DLQ) — not for manual review, but for a dedicated FunctionGraph **reprocessor** that retries with escalating backoff (1 min → 5 min → 30 min → escalate to Cloud Eye alarm). This makes three FunctionGraph instances in total: preprocess (OCR), parse (normalization), and reprocessor (DLQ handler). CTS captures the error context — function name, document ID, error type, and timestamp — so the ops team has a complete incident trail.

For the OCR stage specifically, transient failures (timeouts, throttling) trigger up to 3 automatic retries with exponential backoff before the document lands in the DLQ. At 45,000 invoices/month and an assumed ~1% transient failure rate, that's ~450 automatic retries per month, all handled without human intervention.

A separate concern: what about OCR passes with **low confidence** (<80%)? These are routed to a dedicated DMS topic (`ocr.low_confidence`) that feeds a lightweight manual review queue — displayed in a simple Streamlit dashboard for a compliance analyst to verify. If 90–95% of clean, structured invoices clear the threshold, that leaves roughly 2,250–4,500 documents per month for human review, far fewer than an all-manual process.

---

## Financial Compliance: Not Optional

Financial institutions in Mexico work under **Mexican financial regulation** that expects encryption, auditability, data residency, and strict access control for financial data. We treated those expectations as design inputs, so every architecture decision had compliance implications:

| Requirement | Implementation |
|-------------|---------------|
| Encryption at rest | OBS + KMS envelope encryption |
| Access control | IAM conditional (IP-bound + time-bound + MFA) |
| Audit trail | CTS (Cloud Trace Service) for every FunctionGraph execution |
| Data residency | All services in `la-north-2` (Mexico City 2, Huawei Cloud's LATAM region) |
| Perimeter security | CFW in strict protection mode (not observation) |
| Document retention | OBS lifecycle policies + DWS archival |

The FunctionGraph execution logs in CTS provide an immutable audit trail — every function invocation (OCR, parsing, LLM inference) is logged with timestamp, caller identity, and payload hash. Combined with OBS access logging, this gives regulated financial entities a complete, verifiable chain of custody for every document in the pipeline.

---

## What Actually Shipped (and Why We Cut It Down)

For a **45-minute workshop slot**, the full pipeline was overkill. We shipped a simplified version:

| Component | Original | Workshop Demo |
|-----------|----------|---------------|
| Pipeline | FunctionGraph + DMS + OCR + DeepSeek | **Dify chatbot** with pre-indexed KB |
| Data warehouse | DWS with full ODS→DW→DM→RPT | **DWS** with pre-seeded queries |
| Dashboard | Streamlit + custom | **Streamlit** with pre-computed risk scores |
| Monitoring | Langfuse | **Langfuse** |
| Orchestration | FunctionGraph | Not needed — pre-computed |

The workshop audience (C-suite, not engineers) needed to *touch and feel* the chatbot, not watch pipeline stages. The serverless architecture stayed in the PPT slide and the follow-up technical session.

---

## Lessons Learned

### 1. FunctionGraph + DMS shines at invoice-processing scale
At the volume we sized for (~1,500 invoices/day), the serverless async pipeline is a strong fit. Each component scales independently, and the infrastructure cost between batch windows is effectively zero for Python runtimes on FunctionGraph's pay-per-use model.

### 2. Workshop demos ≠ production architecture
The full FunctionGraph pipeline is what you'd deploy in production. The workshop demo is what fits in one segment of a 45-minute session. Design both, but be honest about the gap.

### 3. Dify as the user-facing layer simplifies everything
Dify's RAG + chatbot interface means non-technical users interact with the system through natural language. The complexity of FunctionGraph + DMS + OCR is hidden behind a single chat interface. This is the right abstraction for enterprise AI.

### 4. Compliance constraints drove better architecture
If conditional IAM, KMS, and CTS hadn't been requirements for regulated financial workloads, we might have cut corners. The constraints pushed us to a design that is more auditable, more secure, and easier for a financial institution to approve.

---

## Reusing the Design

The pattern is portable: object-storage events trigger a serverless function, an event bus sits between OCR, parsing, and LLM stages, low-confidence results go to a human review queue, and every step lands in an audit log. All of it was built with Terraform and synthetic data only. No real customer documents were involved.

---

*Designed in April 2026 for a Technology Innovation Workshop in Mexico City (May 2026). The full FunctionGraph pipeline serves as a reference architecture for regulated document workflows.*
