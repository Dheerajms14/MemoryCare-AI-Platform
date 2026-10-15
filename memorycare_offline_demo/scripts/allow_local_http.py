"""Legacy helper; HTTP is now restricted to the checked-in debug manifest.

Never weaken the main/release manifest. Release apps require HTTPS.
"""
print('No manifest changes needed. HTTP is permitted only in the debug variant.')
print('Local demo: flutter run --dart-define=MEMORYCARE_ALLOW_HTTP=true')
