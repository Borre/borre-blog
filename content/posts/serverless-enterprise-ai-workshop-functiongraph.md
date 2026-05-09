---
title: "Building a Multi-Service Enterprise AI Workshop on Huawei Cloud: A Serverless FunctionGraph Architecture"
description: "How we designed a serverless document analysis pipeline connecting OBS, DMS, FunctionGraph, OCR, DeepSeek, Dify, and DWS for a financial services client."
date: 2026-05-09
draft: false
tags: [huawei-cloud, serverless, functiongraph, enterprise-ai, fintech]
slug: serverless-enterprise-ai-workshop-functiongraph
---

In April 2026, we prepared a Technology Innovation Workshop for a **financial services client in Latin America**. The brief: demonstrate how Huawei Cloud could modernize their document-heavy compliance workflows, risk scoring, and regulatory reporting.

The architecture we designed goes well beyond what we ended up demoing in the room. This post covers the full design — the serverless contract analysis pipeline with **FunctionGraph**, **DMS/Kafka**, **OCR Service**, **DeepSeek**, and **Dify** — plus why we simplified it for a 45-minute workshop.

---

## The Problem

The compliance team reviews contracts, vendor profiles, and transaction anomalies across thousands of entities. The manual process took approximately:

- **2 weeks** to analyze 2,300 vendors for financial risk
- **Days** for a single contract review (OCR → manual extraction → legal review)
- **No unified view**: contracts in PDF silos, vendor data in ERP, credit bureau data in separate systems

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
| **OBS** (Object Storage) | Raw contract storage, extracted text, results |
| **FunctionGraph** | Serverless orchestrator — triggers on OBS upload events |
| **OCR Service** | PDF/JPG → structured text extraction |
| **DMS** (Kafka-compatible) | Async event bus between pipeline stages |
| **FunctionGraph Parse Function** | Post-OCR normalization: tables, formatting, structure |
| **DeepSeek** (via MaaS) | LLM: AI Summary, Metadata, Doc Classification, Risk Clauses |
| **Dify Platform** | RAG knowledge base + AI Document Chatbot |
| **DWS** (Data Warehouse Service) | Structured storage of contract risk results |
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
2. **Auto-scaling to zero** — Between document uploads, there are zero running instances. For this batch processing pattern (upload 50 contracts once a week), this matters.
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

### Why Kafka (DMS) for 50 Documents/Week?

At first glance, Kafka over DMS seems like overkill for 50 contracts per week — a simple synchronous chain or a lightweight task queue would work. The reasoning was forward-looking:

1. **Pipeline stages have different scaling profiles** — OCR is CPU-bound and fast, LLM inference is I/O-bound and slow. Without a buffer, a slow LLM call blocks OCR processing for subsequent documents. DMS decouples them: OCR writes results and returns immediately; the Parse + LLM stages consume at their own pace.

2. **Audit requirements favor async** — Each DMS message carries metadata (document ID, source system, compliance tier). If a regulator requests "show me every document that moved through the pipeline on May 15," the DMS topic replay provides exactly that. A synchronous chain would require reconstructing the sequence from function logs.

3. **The architecture was designed for growth** — The client's roadmap includes tripling document volume within 18 months. Investing in DMS early avoids a painful migration later.

That said, a simpler alternative exists: FunctionGraph can chain stages via synchronous invocation for <100 docs/week. We chose DMS because the client's compliance team valued the audit trail more than the simplified deployment.

What isn't shown in the diagram: each FunctionGraph invocation wraps its stage in try-catch logic, writing failed documents to a **DMS dead-letter queue** (DLQ) for manual review. CTS captures the error context — function name, document ID, error type, and timestamp. The DLQ is monitored via a Cloud Eye alarm, so the operations team gets notified before the compliance team does.

For the OCR stage specifically, transient failures (timeouts, throttling) trigger up to 3 automatic retries with exponential backoff before the document lands in the DLQ. At 50 documents per week, manual DLQ review takes minutes — not hours.

---

## Financial Compliance: Not Optional

The client operates under **CNBV** (Mexico's financial regulator), **Banxico** (central bank), and **Ley Fintech** (Fintech Law) — three regulatory frameworks that collectively mandate encryption, auditability, data residency, and strict access control for financial data processing. Every architecture decision had compliance implications:

| Requirement | Implementation |
|-------------|---------------|
| Encryption at rest | OBS + KMS envelope encryption |
| Access control | IAM conditional (IP-bound + time-bound + MFA) |
| Audit trail | CTS (Cloud Trace Service) for every FunctionGraph execution |
| Data residency | All services in `la-north-2` (Mexico City 2 region) |
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

### 1. FunctionGraph + DMS shines in batch document processing
For this use case (50-100 contracts per week, not 10,000 per hour), the serverless async pipeline is perfect. Each component scales independently, and the infrastructure cost between batches is effectively zero.

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
