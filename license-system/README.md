# Isha Converter iOS — License system

This package adds server-side key verification, a private admin dashboard, device activation limits, expiry, revocation, and app-side enforcement.

## Important before using it

- The app fails closed: Continue to converter remains disabled unless the server says the license is valid.
- The app's current IshaLicenseConfiguration values are placeholders. The iOS app cannot validate any key until you create a Supabase project, deploy the functions, then put that project's URL and publishable key into patches/MLBBConverterApp.swift and rebuild.
- The sb_publishable_ key is intended for client use. Never put a Supabase secret/service-role key in the iOS app, admin HTML, or repository.
- The admin dashboard only issues keys; it does not store plaintext keys after creation. Copy each new key immediately.
- This is a server-side key check, not tamper-proof DRM. A modified IPA could bypass client-side screens, so treat the server as the authority for license-sensitive online operations.

## 1. Create a Supabase project

Create a project at https://database.new. Remember the project reference, project URL, and publishable key.

## 2. Create the database tables

Open the project's SQL Editor and run the entire migration file:
license-system/supabase/migrations/202610290001_isha_license_system.sql

It creates:
- isha_licenses: key SHA-256 hash, prefix, status, expiry, device limit, label, and timestamps.
- isha_license_activations: a license's allowed device identifiers.
- verify_isha_license(...): transaction-safe database procedure callable only by service_role.

Row-level security is enabled, and direct table privileges are revoked from anon and authenticated users.

## 3. Create your administrator account

In Supabase Dashboard → Authentication → Users, add your own email account. Confirm the email if the project's settings require it. Use a strong, unique password.

## 4. Deploy the Edge Functions

Install the Supabase CLI, then run the following commands from the license-system folder:

    supabase login
    supabase link --project-ref YOUR_PROJECT_REF
    supabase secrets set ADMIN_EMAILS="your-admin-email@example.com"
    supabase functions deploy validate-license
    supabase functions deploy admin-licenses

SUPABASE_URL and the server-side Supabase secret are provided to deployed functions by Supabase. ADMIN_EMAILS is a private server-side allowlist: put your own admin email there and only trusted admin emails. The validation function disables gateway JWT verification because the native app sends the publishable key; the function checks the license itself. The admin function retains JWT verification and also checks the authenticated email against ADMIN_EMAILS.

## 5. Configure the iOS app

In patches/MLBBConverterApp.swift, replace the placeholder validation URL with:
https://YOUR_PROJECT_REF.supabase.co/functions/v1/validate-license

Replace YOUR_SUPABASE_PUBLISHABLE_KEY with the project's publishable key. Commit and rebuild the app. Do not use a secret/service-role key in this setting.

The app stores the device identifier and validated license key in iOS Keychain. On every launch it rechecks the saved key online; expired, revoked, over-limit, or unreachable licenses do not unlock the converter. A working internet connection is required for online validation.

## 6. Issue license keys from the private admin page

Open license-system/admin/index.html in a modern browser or host the static folder on a private/admin-only site. Enter the project URL, publishable key, then your admin email and password.

Only emails listed in ADMIN_EMAILS can perform admin actions, even if another person can sign in to Supabase.

Use Generate license to create a key with:
- 7, 30, 90, or 365 days, or lifetime
- a maximum of 1, 2, 3, 5, or 10 devices
- an optional customer/order label

The full key is shown once. Copy it and send it directly to the customer. The database stores only its hash and short prefix. If you lose the key, issue another. Use Revoke to disable a key, or Renew 30d to reactivate it for 30 days from today.

## Troubleshooting

- License server is not configured: the URL/key in the iOS source is still a placeholder, or the app wasn't rebuilt after configuring them.
- License service is not configured correctly: confirm the migration ran and both functions are deployed.
- Admin access denied: make sure the user's exact email is listed in the ADMIN_EMAILS Supabase secret.
- If the app cannot reach the server, it stays locked by design. Check internet connection and deployment status.
