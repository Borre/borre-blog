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

The original design connects **10 Huawei Cloud services** into an asynchronous document analysis pipeline:

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
4. **Cold start is irrelevant** — The pipeline processes documents in batches. A 500ms cold start per batch is invisible against 15s of LLM inference.

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

Each DMS topic acts as a buffer — if OCR produces documents faster than DeepSeek can process them, DMS holds the queue. No back-pressure. No dropped documents.

---

## Financial Compliance: Not Optional

The client operates under CNBV, Banxico, and Ley Fintech regulations. Every architecture decision had compliance implications:

| Requirement | Implementation |
|-------------|---------------|
| Encryption at rest | OBS + KMS envelope encryption |
| Access control | IAM conditional (IP-bound + time-bound + MFA) |
| Audit trail | CTS (Cloud Trace Service) for every FunctionGraph execution |
| Data residency | All services in `la-north-2` (Mexico City 2 region) |
| Perimeter security | CFW in strict protection mode (not observation) |
| Document retention | OBS lifecycle policies + DWS archival |

The FunctionGraph execution logs in CTS provide an immutable audit trail — every OCR call, every LLM inference, every document access is logged with timestamp, caller identity, and payload hash. For a regulated financial entity, this alone can replace weeks of manual compliance reporting.

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

**Requirements:** Huawei Cloud account in `la-north-2`, a MaaS API key, and 15 minutes for `make demo`.

---

*Originally designed for a Technology Innovation Workshop with a financial services client, Mexico City, May 2026. The full FunctionGraph pipeline is available as a reference architecture for financial services clients.*
