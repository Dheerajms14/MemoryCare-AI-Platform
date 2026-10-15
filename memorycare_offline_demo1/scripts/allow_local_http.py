"""Allow local plain HTTP in the generated Android manifest for the lab demo."""
from pathlib import Path

manifest = Path(__file__).resolve().parents[1] / "mobile/android/app/src/main/AndroidManifest.xml"
if not manifest.exists():
    raise SystemExit("First run 'flutter create . --platforms=android' inside mobile/")
text = manifest.read_text(encoding="utf-8")
if "android.permission.INTERNET" not in text:
    text = text.replace(
        "<application",
        '<uses-permission android:name="android.permission.INTERNET" />\n    <application',
        1,
    )
if "usesCleartextTraffic" not in text:
    text = text.replace(
        "<application", '<application android:usesCleartextTraffic="true"', 1
    )
manifest.write_text(text, encoding="utf-8")
print("Configured local HTTP for Android demo:", manifest)
