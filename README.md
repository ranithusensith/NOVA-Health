# NOVA Health 🩺
## AGI-Powered Personal Health Intelligence Companion
NOVA Health is an AGI-inspired personal health intelligence platform designed to bring different types of health and lifestyle information into one unified system.
Instead of processing medical records, prescriptions, nutrition, wearable data, sleep, mood, symptoms, and environmental information separately, NOVA Health uses a centralized **Health Intelligence Engine** to maintain context, identify relationships between different health factors, and provide personalized, context-aware health assistance.
> **Note:** NOVA Health demonstrates AGI-inspired and agentic reasoning principles for healthcare assistance. It does not attempt to create true human-level AGI.
---
## 🎯 Project Goals
The main goal of NOVA Health is to develop an intelligent healthcare assistant capable of:
- Integrating heterogeneous health and lifestyle data
- Maintaining a continuously updated personal health context
- Reasoning across multiple health domains
- Providing personalized health insights and recommendations
- Processing medical documents and images
- Monitoring medication, nutrition, sleep, mood, and activity
- Integrating supported wearable health data
- Providing context-aware notifications and reminders
- Generating daily and long-term health insights
---
## 🧠 AGI Health Intelligence Engine
The **Health Intelligence Engine** is the central intelligence component of NOVA Health.
It combines information from multiple sources into a unified health context.
```text
Medical Records
       │
Prescriptions ─────┐
Symptoms ──────────┤
Nutrition ──────────┤
Wearable Data ──────┤
Sleep ──────────────┤
Mood ───────────────┤
Medication ─────────┤
Weather ────────────┤
Health History ─────┘
          │
          ▼
┌─────────────────────────┐
│ Health Intelligence     │
│ Engine                  │
│                         │
│ Context Management      │
│ Multimodal Analysis     │
│ Agentic Reasoning       │
│ Knowledge Reasoning     │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ Personalized Health     │
│ Assistance              │
│                         │
│ Insights                │
│ Recommendations         │
│ Alerts & Reminders      │
│ Daily Health Reports    │
│ Health Assistant        │
└─────────────────────────┘

⸻

✨ Core Features

🧠 AGI Health Intelligence

* Cross-domain health reasoning
* Personal health context
* Personalized recommendations
* Context-aware assistance
* AGI Health Chat
* Daily health reports

📄 Medical Intelligence

* Prescription scanning
* OCR-based information extraction
* Medical report scanning
* Structured medical records
* Medication information and reminders

🍎 Nutrition Intelligence

* Food image analysis
* Nutrition estimation
* Water tracking
* Nutrition monitoring
* Personalized nutrition insights

❤️ Health & Lifestyle Tracking

* Symptom tracking
* Mood monitoring
* Sleep tracking
* Medication tracking
* Period tracking
* Activity monitoring

⌚ Wearable Integration

Integration with supported health platforms and wearable devices for information such as:

* Steps
* Heart rate
* Sleep
* Calories
* SpO₂ where supported
* Physical activity

🌦️ Environmental Intelligence

Weather information can be incorporated into the user’s health context to provide context-aware suggestions such as:

* Hydration reminders
* Weather-related alerts
* Outdoor activity considerations
* Sun and weather awareness

🚨 Emergency Assistance

NOVA Health includes a controlled emergency workflow:

Abnormal Event
      │
      ▼
User Warning
      │
      ▼
User Confirmation
      │
      ▼
No Response / Confirmation
      │
      ▼
Emergency Contact Workflow

⸻

🏗️ System Architecture

                    ┌─────────────────────┐
                    │   Flutter Mobile    │
                    │        App          │
                    └──────────┬──────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │      Backend        │
                    │    API / Services   │
                    └──────────┬──────────┘
                               │
             ┌─────────────────┼─────────────────┐
             ▼                 ▼                 ▼
       Health Data        Medical Data      External Data
       Wearables          Prescriptions      Weather
       Sleep              Reports            Health APIs
       Nutrition          Symptoms
             │                 │                 │
             └─────────────────┼─────────────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │ Health Intelligence │
                    │       Engine        │
                    │                     │
                    │ Context Management  │
                    │ Multimodal AI       │
                    │ Agentic Reasoning   │
                    │ Knowledge Reasoning │
                    └──────────┬──────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │ Personalized Health │
                    │     Assistance      │
                    └─────────────────────┘

⸻

🔄 Health Data Flow

User
 │
 ├── Symptoms
 ├── Medication
 ├── Food
 ├── Mood
 ├── Sleep
 ├── Water
 └── Health Information
          │
          ▼
   ┌───────────────┐
   │ Mobile App    │
   └───────┬───────┘
           │
           ▼
   ┌───────────────┐
   │ Backend / API │
   └───────┬───────┘
           │
           ▼
   ┌─────────────────────┐
   │ Health Context      │
   │ Integration Layer   │
   └──────────┬──────────┘
              │
              ▼
   ┌─────────────────────┐
   │ AGI Health          │
   │ Intelligence Engine │
   └──────────┬──────────┘
              │
              ▼
   ┌─────────────────────┐
   │ Personalized        │
   │ Health Assistance   │
   └─────────────────────┘

⸻

🧩 Health Context

NOVA Health uses a common structure to allow different modules to communicate with the Health Intelligence Engine.

HealthEvent
├── timestamp
├── type
├── source
├── value
├── unit
├── confidence
└── metadata

Example:

Type: Heart Rate
Value: 82
Unit: bpm
Source: Smart Watch
Timestamp: 2026-09-24 08:30

This structure allows information from different domains to be combined into a unified health context.

⸻

🛠️ Technology Stack

Mobile Application

* Flutter
* Dart

Backend

* Python
* FastAPI / Flask

Database

* PostgreSQL / Firebase

Artificial Intelligence

* Large Language Models (LLMs)
* Agentic AI architecture
* Knowledge-based reasoning
* Multimodal AI
* OCR
* Computer Vision

Health & External APIs

* Apple HealthKit
* Supported Samsung Health APIs
* Weather API

Security

* Authentication
* OAuth
* Encryption
* Access control
* Secure API communication

Development Tools

* Visual Studio Code
* Android Studio
* Git
* GitLab (issues, merge requests, and CI)

⸻

📁 Project Structure

NOVA-Health/
│
├── mobile/
│
├── backend/
│   ├── api/
│   ├── models/
│   ├── services/
│   └── database/
│
├── ai/
│   ├── agi_engine/
│   ├── agents/
│   ├── prompts/
│   ├── knowledge/
│   └── context/
│
├── medical/
│   ├── prescription/
│   ├── reports/
│   └── OCR/
│
├── nutrition/
│   ├── food_detection/
│   ├── nutrition/
│   └── tracking/
│
├── wearable/
│   ├── apple_health/
│   └── samsung_health/
│
├── context/
│   ├── weather/
│   ├── notifications/
│   └── emergency/
│
├── docs/
│   ├── architecture/
│   ├── api/
│   └── research/
│
├── tests/
│
├── README.md
├── .gitignore
└── LICENSE

⸻

🔐 Privacy & Security

Health information is sensitive. NOVA Health is designed with security considerations including:

* Secure authentication
* Private health profiles
* Access control
* Encryption
* Secure API communication
* Controlled emergency workflows

The system is designed as a health assistance and information platform and is not intended to replace qualified medical professionals.

⸻

👥 Target Users

NOVA Health is designed for:

* General health and wellness users
* People managing medications
* Users maintaining medical records
* Nutrition and fitness users
* Supported smartwatch users
* Individuals who may require emergency assistance
* Users seeking a centralized intelligent health platform

⸻

🚀 Development Roadmap

Phase 1 — Foundation

* Literature review
* Requirements analysis
* AGI research
* System architecture
* Database design
* UI planning

Phase 2 — Application Core

* Authentication
* Private health profile
* Database
* Dashboard
* Core mobile application

Phase 3 — Intelligence

* Prescription scanning
* Medical report scanning
* Food recognition
* AGI Health Intelligence Engine

Phase 4 — Integrations

* Wearable integration
* Weather integration
* Medication reminders
* Mood and sleep tracking
* Nutrition tracking
* Emergency workflows

Phase 5 — Intelligence & Evaluation

* Daily AGI health reports
* Cross-domain reasoning
* System integration
* Testing
* Security
* Performance optimization
* Final evaluation

⸻

📚 Research Focus

The project investigates how AGI-inspired reasoning, multimodal intelligence, and agentic architectures can be applied to create a unified personalized health assistance system.

Research Question

How can AGI-inspired reasoning and multimodal intelligence be applied to create a unified, personalized healthcare assistant capable of reasoning across multiple health domains?

⸻

⚠️ Disclaimer

NOVA Health is an academic software project intended for health information, monitoring, and assistance.

It is not intended to independently diagnose medical conditions, prescribe medication, change medication dosages, or replace professional medical advice.

⸻

👨‍💻 Development Team

The project is maintained by an eight-person team. Add all current members to the GitLab project with suitable roles; the roster below reflects the names currently documented.

NOVA Health — Group Project

Name	Index
W.L.R. Sensith	36453
S.D. Kaluwitharana	36880
K.P.C.J. Bimsari	37054
N.H.M. Sivmini	37097
R.G.M.N. Jayawardhana	36909
M.L.D.B. Sithari	36857

Supervisor: Mr. Diluka Wijesinghe
