# Birthday Reminder v1.1.0

A simple Flutter birthday reminder app with Hindi voice notifications and shareable birthday cards.

## Features

- Add, edit and delete birthdays.
- Birthday reminders one day before at 9 AM, 2 PM and 8 PM.
- Hindi TTS notification message.
- Exact-alarm permission with safe inexact fallback.
- Safe handling of invalid saved data and February 29 birthdays.
- **Birthday Card Creator:** choose the child’s photo from the gallery, add class, school name and a custom birthday message.
- Generates a PNG birthday card and opens the Android share sheet for WhatsApp and other apps.
- Modern Android embedding (Flutter embedding v2 only).
- Codemagic Android release workflow included.

## Build

Use the `codemagic.yaml` workflow for Android. The Play Store release should be signed with a release keystore configured in Codemagic before publishing.


## Birthday Card Designs

- Six selectable birthday card templates.
- Child photo from gallery.
- Child name, optional class, school name and custom message.
- Live preview and one-tap image sharing to WhatsApp or any compatible sharing app.
