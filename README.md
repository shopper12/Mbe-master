# Bar Master — US Bar & SQE
Mobile-first Next.js/PWA with Supabase Auth and owner-scoped data. No paid AI APIs. Repository is currently public; do not commit user study content or credentials.

## Current implementation
- Issue-based textbook and recursive decision map, separate MBE/SQE1 views.
- Flashcard recall with simple fixed review intervals (not FSRS), database-saved ratings.
- MBE 4-choice and SQE1 5-choice question fetch and server grading; unreviewed questions excluded by default.
- California essay prompt, drafting, save/submit, model answer and rubric self-assessment; not automated AI grading or official grading.
- JSON import, export; source verification workflow, full syllabus population, backup restore, advanced analytics, native APK and offline sync remain incomplete.
- PWA manifest and responsive layout. PWA installability on Android and all browser flows have not yet been tested.

## Local run
Use Node 22+, npm install, copy .env.example to .env.local and set the Supabase publishable key (not a secret/service-role key). npm run dev. For a clean database apply migrations in order. The existing project already has these migrations applied. Create your own Supabase Auth account, then import a v2 JSON bundle. See docs/generation-contract-v2.md. For scored practice review status must be approved; currently an explicit unreviewed practice toggle is available, and complete review UI is pending.

## Verification
Database integration smoke check on 2026-11-26 used a rolled-back synthetic fixture and simulated JWT subject: PASS chapter import, MBE/SQE import, duplicate detection, answer omission in card RPC, unreviewed filtering, both answer grading, flashcard review insert/update and essay draft save. Initial ambiguous flashcard conflict target was corrected and the test repeated successfully. This was not an end-to-end browser/auth or adversarial cross-account RLS test. Playwright smoke test source exists, but browser execution, dependency lockfile and production build have not been verified. Vercel project creation was previously rejected with 403; no deployed URL yet. No paid service was enabled.
