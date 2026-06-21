<div align="center">

# 🧘‍♀️ ZenFlow AI

**Your Intelligent, On-Device Yoga & Fitness Companion**

[![Flutter](https://img.shields.io/badge/Flutter-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://flutter.dev/)
[![Supabase](https://img.shields.io/badge/Supabase-3ECF8E?style=for-the-badge&logo=supabase&logoColor=white)](https://supabase.com/)
[![TensorFlow Lite](https://img.shields.io/badge/TensorFlow_Lite-FF6F00?style=for-the-badge&logo=tensorflow&logoColor=white)](https://www.tensorflow.org/lite)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](https://opensource.org/licenses/MIT)

*Achieve mindfulness and perfect your posture with real-time AI tracking.*

---

</div>

## 📖 Table of Contents
- [About the Project](#-about-the-project)
- [Key Features](#-key-features)
- [Tech Stack](#-tech-stack)
- [How It Works](#-how-it-works)
- [Getting Started](#-getting-started)
- [Project Architecture](#-project-architecture)
- [Contributing](#-contributing)
- [License](#-license)

---

## 💡 About the Project

**ZenFlow AI** is a cutting-edge mobile application designed to bridge the gap between technology and wellness. By leveraging powerful on-device machine learning, the app provides real-time pose estimation to analyze your yoga asanas and workout movements without sending sensitive camera feeds to the cloud.

With a beautifully crafted UI, seamless backend synchronization via Supabase, and a privacy-first approach, ZenFlow AI is your ultimate personal trainer right in your pocket.

---

## ✨ Key Features

| Feature | Description |
| :--- | :--- |
| 👁️ **Real-time Pose Estimation** | Utilizes **MoveNet Thunder** via TFLite to track skeletal points and provide immediate form feedback. |
| 🔐 **Secure Authentication** | Frictionless email/password sign-ups and profile management powered by **Supabase Auth**. |
| 📊 **Interactive Dashboard** | Beautiful, dynamic charts (`fl_chart`) that visualize your fitness journey, streaks, and progress. |
| 🏋️ **Session Tracking** | Log specific workouts, track duration, and maintain an organized history of your activities. |
| 📈 **Detailed Reports** | Gain insights into your consistency and performance through deep-dive analytics. |
| 🎨 **Modern Aesthetics** | A premium user interface adhering to **Material 3** guidelines, complete with seamless dark/light mode transitions. |

---

## 🛠 Tech Stack

Our technology choices prioritize performance, scalability, and developer experience.

### **Frontend**
- **Framework:** [Flutter](https://flutter.dev/) (Dart) - *Cross-platform UI.*
- **State Management:** [Riverpod](https://riverpod.dev/) (`flutter_riverpod`) - *Robust, scalable state.*
- **UI & Styling:** `google_fonts`, `cupertino_icons`, `fl_chart`.

### **Backend (Supabase)**
- **Database:** PostgreSQL with Row Level Security (RLS).
- **Authentication:** Supabase Auth ecosystem.

### **Machine Learning & Hardware**
- **Model:** MoveNet Thunder (`tflite_flutter`) - *High-accuracy pose detection.*
- **Camera integration:** `camera` plugin for low-latency frame processing.

### **Utilities**
- **Storage:** `shared_preferences`, `flutter_secure_storage`.
- **Environment Management:** `flutter_dotenv`.
- **Sensors & System:** `wakelock_plus`, `connectivity_plus`, `audioplayers`.

---

## 🧠 How It Works

1. **Capture:** The app accesses your device camera, feeding frames directly into the local TFLite engine.
2. **Analyze:** The MoveNet Thunder model infers 17 keypoints of the human body in real-time.
3. **Feedback:** A geometry engine (using the `asana_registry.json`) matches your current skeletal structure against ideal yoga poses.
4. **Sync:** Workout statistics are pushed securely to your Supabase PostgreSQL database.

---

## 🚀 Getting Started

Follow these instructions to get a local copy up and running on your machine.

### Prerequisites

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (`>= 3.11.5`)
- A [Supabase](https://supabase.com/) Account & Project.
- A physical device or emulator for testing camera functionality.

### Installation

<details>
<summary><b>1. Clone the repository</b></summary>

```bash
git clone https://github.com/Shaunak-Rahatekar/ZENFLOW_AI.git
cd zenflow_ai
```
</details>

<details>
<summary><b>2. Install Dependencies</b></summary>

```bash
flutter pub get
```
</details>

<details>
<summary><b>3. Environment Setup</b></summary>

Create a `.env` file in the root directory and add your Supabase credentials:

```env
SUPABASE_URL=your_supabase_project_url
SUPABASE_ANON_KEY=your_supabase_anon_key
```

*Note: Alternatively, use `--dart-define` during the flutter run command.*
</details>

<details>
<summary><b>4. Database Initialization</b></summary>

Navigate to your Supabase project's SQL Editor. Copy the contents of `supabase_schema.sql` and run it to set up tables, relationships, and Row Level Security (RLS) policies.
</details>

<details>
<summary><b>5. Run the App</b></summary>

```bash
flutter run
```
</details>

---

## 📂 Project Architecture

A glimpse into how the repository is structured:

```text
lib/
 ├── core/          # App shell, constants, theme, routing, and shared UI
 ├── features/      # Feature-driven modules
 │   ├── auth/      # Login, Registration, Profile
 │   ├── dashboard/ # Home stats, charts
 │   ├── reports/   # Historical data view
 │   └── workout/   # Camera view, TFLite integration, Pose logic
 └── main.dart      # Entry point & Supabase initialization
```

---

## 🤝 Contributing

We love the open-source community! If you have a suggestion that would make this better, please fork the repo and create a pull request. 

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

---

## 📄 License

Distributed under the MIT License. See `LICENSE` for more information.

<div align="center">
  <i>Built with ❤️ using Flutter and Supabase.</i>
</div>
