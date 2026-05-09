---
title: "Building a Multi-Service Enterprise AI Workshop on Huawei Cloud: A Serverless FunctionGraph Architecture"
description: "How we designed a serverless document analysis pipeline connecting OBS, DMS, FunctionGraph, OCR, DeepSeek, Dify, and DWS for a financial services client processing 45,000+ invoices per month."
date: 2026-05-09
draft: false
tags: [huawei-cloud, serverless, functiongraph, enterprise-ai, fintech]
slug: serverless-enterprise-ai-workshop-functiongraph
---

In April 2026, we prepared a Technology Innovation Workshop for a **financial services client in Latin America**. The brief: demonstrate how Huawei Cloud could modernize their document-heavy compliance workflows, risk scoring, and regulatory reporting.

The architecture we designed goes well beyond what we ended up demoing in the room. This post covers the full design — the serverless **invoice and contract analysis pipeline** with **FunctionGraph**, **DMS/Kafka**, **OCR Service**, **DeepSeek**, and **Dify** — plus why we simplified it for a 45-minute workshop.

---

## The Problem

The compliance team reviews **invoices, vendor profiles, and transaction anomalies** across thousands of entities. The manual process involved:

- **45,000+ invoices per month** — each requiring OCR extraction, validation against ERP, and compliance scoring
- **~3 days** for a single vendor on-boarding (document review → OCR extraction → legal validation → ERP update)
- **No unified view**: PDF silos across 3 business units, vendor data in ERP, credit bureau data in separate systems

## The Full Architecture

The original design connects **9 Huawei Cloud services** into an asynchronous document analysis pipeline:

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

1. **Event-driven triggers** — An OBS PUT event fires the function. No polling, no EC2 sitting idle.
2. **Auto-scaling to zero** — Between batch uploads, there are zero running instances. At 45,000 invoices per month (~1,500/day), the pipeline scales up during business hours, processes the batch, and releases resources.
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

### Why DMS (Kafka) at 45,000 Invoices/Month

At this scale, an async event bus isn't optional — it's structural. Here's why:

1. **Pipeline stages have different scaling profiles** — OCR is CPU-bound and processes ~1 page/second per instance. LLM inference is I/O-bound and takes 3-15s per document. Without a buffer, a slow LLM call blocks OCR for subsequent invoices. DMS decouples them: the OCR stage writes results and returns immediately; downstream consumers (Parse + LLM) process at their own rate.

2. **Burst absorption** — Invoices arrive in waves (end-of-month peaks, supplier onboarding batches). DMS queues up to 72 hours of backlog, so a 2x or 3x burst in document volume doesn't require over-provisioning compute.

3. **Audit requirements favor async** — Each DMS message carries metadata (document ID, source system, compliance tier). Topic replay provides a verifiable sequence of every document processed on any given day — a synchronous chain would require reconstructing from overlapping function logs.

4. **Individual stage scaling** — With DMS, each consumer group (Parse, LLM, Dify embedder) scales independently according to its own bottleneck. If LLM inference becomes the constraint (the likeliest scenario at this volume), we add more consumer instances to the `parsed.documents` topic without touching the OCR or embedding pipelines.

### Error Handling & Resilience

Each FunctionGraph invocation wraps its stage in try-catch logic. Failed documents land in a **DMS dead-letter queue** (DLQ) — not for manual review, but for a dedicated FunctionGraph **reprocessor** that retries with escalating backoff (1 min → 5 min → 30 min → escalate to Cloud Eye alarm). This makes three FunctionGraph instances in total: preprocess (OCR), parse (normalization), and reprocessor (DLQ handler). CTS captures the error context — function name, document ID, error type, and timestamp — so the ops team has a complete incident trail.

For the OCR stage specifically, transient failures (timeouts, throttling) trigger up to 3 automatic retries with exponential backoff before the document lands in the DLQ. At 45,000 invoices/month, with a ~1% transient failure rate, that's ~450 automatic retries per month — all handled without human intervention.

A separate concern: what about OCR passes with **low confidence** (<80%)? These are routed to a dedicated DMS topic (`ocr.low_confidence`) that feeds a lightweight manual review queue — displayed in a simple Streamlit dashboard for a compliance analyst to verify. At typical OCR quality levels for structured invoices (90-95% confidence on clean PDFs), this represents 2,000-4,500 documents per month requiring human review, a dramatically better ratio than the current all-manual process.

---

## Financial Compliance: Not Optional

The client operates under **CNBV** (Mexico's financial regulator), **Banxico** (central bank), and **Ley Fintech** (Fintech Law) — three regulatory frameworks that collectively mandate encryption, auditability, data residency, and strict access control for financial data processing. Every architecture decision had compliance implications:

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
For this use case (45,000 invoices per month ≈ 1,500/day), the serverless async pipeline is a strong fit. Each component scales independently, and the infrastructure cost between batch windows is effectively zero for Python runtimes on FunctionGraph's pay-per-use model.

### 2. Workshop demos ≠ production architecture
The full FunctionGraph pipeline is what you'd deploy in production. The workshop demo is what fits in 8 minutes. Design both, but be honest about the gap.

### 3. Dify as the user-facing layer simplifies everything
Dify's RAG + chatbot interface means non-technical users interact with the system through natural language. The complexity of FunctionGraph + DMS + OCR is hidden behind a single chat interface. This is the right abstraction for enterprise AI.

### 4. Compliance constraints drove better architecture
If IAM conditional, KMS, and CTS hadn't been mandatory (CNBV), we might have cut corners. The regulation forced us into a design that is more auditable, more secure, and ultimately more sellable to financial enterprises.

---

## Try It Yourself

The Terraform modules, synthetic data generators, and Dify configurations are open-source:

```
git clone https://github.com/Borre/ayco-huawei-cloud.git
cd ayco-huawei-cloud
cp .env.example .env  # Fill in your credentials
make demo
```

**Requirements:** Huawei Cloud account in `la-north-2`, a MaaS API key, and 15 minutes for the `make demo` script *after* `terraform apply` finishes provisioning (~5-8 min for the first run; subsequent runs use cached state).

---

*Originally designed for a Technology Innovation Workshop with a financial services client, Mexico City, May 2026. The full FunctionGraph pipeline is available as a reference architecture for financial services clients.*
