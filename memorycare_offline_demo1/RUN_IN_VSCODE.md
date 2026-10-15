# Run MemoryCare 2.0 in VS Code

## 1. Extract and open

Extract the ZIP and open the `memorycare_offline_demo` folder in VS Code.

## 2. Start the backend

Open the first PowerShell terminal:

```powershell
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r .\backend\requirements.txt
cd .\backend
..\.venv\Scripts\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Keep this terminal running.

## 3. Connect the Motorola phone

Enable USB debugging, connect the cable and approve the authorization message on the phone.

```powershell
& "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" devices
```

The result must show `ZD222CCLFX device`, not `unauthorized`.

## 4. Install Flutter packages and run

Open a second PowerShell terminal:

```powershell
cd .\mobile
& "C:\Users\Dheeraj\Downloads\flutter\bin\flutter.bat" clean
& "C:\Users\Dheeraj\Downloads\flutter\bin\flutter.bat" pub get
& "C:\Users\Dheeraj\Downloads\flutter\bin\flutter.bat" run -d ZD222CCLFX
```

## 5. Sign in from the phone

Run `ipconfig` on the PC. In the app's **Connection settings**, enter:

```text
http://PC_WIFI_IPV4_ADDRESS:8000
```

Example only: `http://192.168.0.106:8000`

Patient login: `patient / demo1234`.

## 6. Open caregiver dashboard

On the PC, open:

```text
http://127.0.0.1:8000/dashboard
```

Caregiver login: `caregiver / demo1234`.

## 7. First voice test

1. Select Kannada, Hindi or English.
2. Approve microphone permission.
3. Add a reminder and press **Listen**.
4. Add a Memory Vault item and record a familiar voice.
5. Tap the large microphone and say “Open reminders”.
6. If Kannada or Hindi is not spoken, install that language in Android text-to-speech settings.
