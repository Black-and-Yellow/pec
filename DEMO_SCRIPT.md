# FinGuard Demo Script (3–4 minutes)

## 0:00–0:20 — Opening

**Say:** “A UPI request can look ordinary while hiding urgency, an unfamiliar recipient, or a suspicious payment note. FinGuard gives the user a quick, explainable risk check before they decide what to do.”

**On screen:** Open FinGuard’s welcome screen. Point briefly to **Deterministic score**, **Explainable evidence**, and **No bank credentials**. Select **Continue privately without an account**.

## 0:20–0:45 — Home and privacy-first flow

**Say:** “The home screen keeps the important choices clear: scan a QR, paste a UPI link, or check the message that came with it. You can explore the product without creating an account.”

**On screen:** Pause on the home visual and show **Scan QR**, **Paste UPI Link**, and **Check suspicious message**. Scroll to **Try with demo data**, then select **Start 90-second demo**.

## 0:45–1:25 — Risk Lab: SAFE, CAUTION, HIGH RISK

**Say:** “Risk Lab uses bundled demo data, so this walkthrough is fast, repeatable, and completely view-only. The SAFE example has no warning signals, so FinGuard deliberately leaves a legitimate payment alone. The CAUTION example shows warning signs that deserve an independent check. The HIGH RISK example combines stronger signals and tells the user to stop.”

**On screen:** In **Risk Lab**, move through **SAFE**, **CAUTION**, and **HIGH RISK** with **Next**; use **Previous** if needed. Open one scenario with **Open view-only result**.

**Say:** “Every result shows the recipient, amount, score, and ‘Why this score.’ The score and verdict come only from FinGuard’s deterministic backend policy. Optional AI can add tightly validated context signals, but it cannot choose or change the score.”

## 1:25–1:55 — Real input paths

**On screen:** Return home and briefly show each path:

1. Select **Scan QR**; point out **Can’t scan it?**, **Upload QR image**, and **Paste a UPI link instead** as fallbacks.
2. Select **Paste UPI Link**; on **Check UPI link**, point to **UPI payment link**, **Use reliable demo**, and **Analyze payment**.
3. Return and select **Check suspicious message**; point to **Message text**, **Choose message screenshot**, **Allow optional Gemini analysis**, and **Analyze message**.

**Say:** “The same explanation-first design works whether the request arrives as a QR, a link, or a suspicious message. Inputs are treated as untrusted, and the demo option avoids exposing real payment details.”

## 1:55–2:35 — Payee trust: the CIBIL question, answered

**Say:** “The judges asked whether a UPI ID can carry a CIBIL-style score. Literally, no — NPCI publishes no per-VPA history, so nobody outside a PSP can read it. But CIBIL is not the RBI either. It is a bureau holding what its member banks contribute. So we built the bureau.”

**On screen:** Home → **Check a UPI ID**. Enter `coffee.corner@okaxis`.

**Say:** “Grade A+. Known to the network for over a year, checked by four hundred distinct devices, nothing adverse on file. Five factors, each with its evidence.”

**On screen:** Enter `sbi.refund@okaxis`.

**Say:** “Grade D, and it has no history at all — this one is caught on the address alone. It invokes SBI from a handle any individual can register in a minute. A real SBI collection account would not need to.”

**On screen:** Enter a made-up address such as `new.bakery@okhdfcbank`.

**Say:** “And here is the part we think matters most. Grade NEW, and *no number at all*. A brand-new legitimate shop is not a scam — it is a thin file, exactly as a credit bureau returns ‘no history’ rather than a bad score. Showing a high number here would be an endorsement of an address nobody has ever paid.”

## 2:35–2:55 — Call detection

**Say:** “Almost every large UPI fraud is talked through live, because a caller can override hesitation that a message cannot. So when you run a check, FinGuard reads once whether a call is in progress — including a WhatsApp call, which needs no permission at all — and weighs it. A live call plus a screen-sharing app installed is the exact digital-arrest setup, and that pairing alone pauses the handoff.”

**On screen:** Show the **Call detection** card under **Account & privacy**.

**Say:** “It is a snapshot at check time, not a background listener. It never reads a number or a call log, and it cannot see a call that starts after the result is on screen. We would rather state that boundary than overclaim it.”

## 2:55–3:20 — User control and honest boundary

**Say:** “FinGuard advises; the user stays in control. A live result never silently opens a payment app. **Continue to UPI app** is a separate user action, and CAUTION or HIGH RISK requires independent-verification acknowledgements plus an explicit warning confirmation. The user can always choose **Stop here** or **Check recipient**.”

**On screen:** Point to the result actions without starting any external handoff. Keep the bundled demo result view-only.

**Say:** “FinGuard does not intercept or reverse payments, access a bank or NPCI system, block an account, or submit a fraud report. This presentation uses demo data and makes no real payment. Its purpose is focused: explain risk clearly before the user makes the final decision.”

## Close

**Say:** “FinGuard turns a rushed payment moment into a short, informed pause—clear evidence, deterministic scoring, and explicit human confirmation.”
