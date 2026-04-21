// src/handler.ts — abhix-portfolio-lambda
// Receives contact form submissions from abhix.in and sends email via Gmail SMTP.
//
// Environment variables (set in .env locally, Lambda env vars in prod):
//   EMAIL_USER         — Gmail address used as SMTP auth + sender
//   EMAIL_APP_PASSWORD — Gmail App Password (16-char, NOT your login password)
//   OWNER_EMAIL        — inbox where contact emails are delivered (defaults to EMAIL_USER)
//   ALLOWED_ORIGIN     — portfolio domain for CORS (e.g. https://www.abhix.in)

import { APIGatewayProxyEvent, APIGatewayProxyResult } from 'aws-lambda'
import nodemailer from 'nodemailer'

// ─── Config ───────────────────────────────────────────────────────────────────
const EMAIL_USER         = process.env.EMAIL_USER         ?? ''
const EMAIL_APP_PASSWORD = process.env.EMAIL_APP_PASSWORD ?? ''
const OWNER_EMAIL        = process.env.OWNER_EMAIL        || EMAIL_USER
const ALLOWED_ORIGIN     = process.env.ALLOWED_ORIGIN     ?? 'https://www.abhix.in'

// ─── Nodemailer — reused across warm Lambda invocations ───────────────────────
const transporter = nodemailer.createTransport({
  host: 'smtp.gmail.com',
  port: 587,
  secure: false,
  auth: { user: EMAIL_USER, pass: EMAIL_APP_PASSWORD },
  tls: { rejectUnauthorized: false },
})

// ─── Types ────────────────────────────────────────────────────────────────────
interface ContactPayload {
  name: string
  email: string
  subject: string
  message: string
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
const CORS_HEADERS = {
  'Access-Control-Allow-Origin':  ALLOWED_ORIGIN,
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
}

function respond(statusCode: number, body: object): APIGatewayProxyResult {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
    body: JSON.stringify(body),
  }
}

function validate(p: Partial<ContactPayload>): string | null {
  if (!p.name?.trim()    || p.name.trim().length < 2)    return 'Name must be at least 2 characters.'
  if (!p.email?.trim()   || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(p.email.trim())) return 'A valid email is required.'
  if (!p.subject?.trim() || p.subject.trim().length < 5) return 'Subject must be at least 5 characters.'
  if (!p.message?.trim() || p.message.trim().length < 10) return 'Message must be at least 10 characters.'
  return null
}

// ─── Email HTML — styled to match portfolio dark theme ───────────────────────
function buildEmail(p: ContactPayload): string {
  return `<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#0f0e0c;font-family:'Segoe UI',Arial,sans-serif">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#0f0e0c;padding:40px 0">
    <tr><td align="center">
      <table width="580" cellpadding="0" cellspacing="0" style="max-width:580px;width:100%">

        <!-- Header -->
        <tr>
          <td style="background:#1a1713;border-radius:10px 10px 0 0;padding:20px 36px;border-bottom:2px solid #d4891a">
            <span style="font-size:11px;font-family:monospace;letter-spacing:0.14em;color:#d4891a;text-transform:uppercase">
              ✉ &nbsp; Portfolio Contact — abhix.in
            </span>
          </td>
        </tr>

        <!-- Body -->
        <tr>
          <td style="background:#161410;padding:32px 36px;border:1px solid #2a2620;border-top:none">

            <!-- Sender info table -->
            <table width="100%" cellpadding="0" cellspacing="0"
              style="background:#1a1713;border:1px solid #2a2620;border-radius:8px;margin-bottom:24px">
              <tr>
                <td style="padding:11px 16px;font-size:11px;color:#9c9080;width:80px;
                           font-family:monospace;text-transform:uppercase;letter-spacing:0.08em;
                           border-bottom:1px solid #2a2620">From</td>
                <td style="padding:11px 16px;font-size:13px;color:#e8e3d8;border-bottom:1px solid #2a2620">
                  ${p.name} &lt;${p.email}&gt;
                </td>
              </tr>
              <tr>
                <td style="padding:11px 16px;font-size:11px;color:#9c9080;
                           font-family:monospace;text-transform:uppercase;letter-spacing:0.08em">Subject</td>
                <td style="padding:11px 16px;font-size:13px;color:#e8e3d8">${p.subject}</td>
              </tr>
            </table>

            <!-- Message -->
            <div style="background:#1a1713;border-left:3px solid #d4891a;border-radius:0 6px 6px 0;
                        padding:20px 24px;margin-bottom:24px">
              <p style="margin:0;font-size:14px;color:#9c9080;line-height:1.8;white-space:pre-line">${p.message}</p>
            </div>

            <p style="margin:0;font-size:12px;color:#5c5448">
              Hit <strong style="color:#9c9080">Reply</strong> to respond directly to ${p.name}.
            </p>
          </td>
        </tr>

        <!-- Footer -->
        <tr>
          <td style="background:#1a1713;border:1px solid #2a2620;border-top:none;
                     border-radius:0 0 10px 10px;padding:14px 36px;text-align:center">
            <span style="font-size:10px;color:#5c5448;font-family:monospace;letter-spacing:0.08em">
              abhix.in · abhix-portfolio-lambda · ${new Date().getFullYear()}
            </span>
          </td>
        </tr>

      </table>
    </td></tr>
  </table>
</body>
</html>`
}

// ─── Handler ──────────────────────────────────────────────────────────────────
export const handler = async (event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> => {
  // CORS preflight
  if (event.httpMethod === 'OPTIONS') {
    return respond(200, {})
  }

  if (event.httpMethod !== 'POST') {
    return respond(405, { success: false, message: 'Method not allowed.' })
  }

  // Parse body
  let payload: Partial<ContactPayload>
  try {
    const raw = event.isBase64Encoded
      ? Buffer.from(event.body ?? '', 'base64').toString()
      : (event.body ?? '{}')
    payload = JSON.parse(raw)
  } catch {
    return respond(400, { success: false, message: 'Invalid JSON body.' })
  }

  // Validate input
  const validationError = validate(payload)
  if (validationError) {
    return respond(400, { success: false, message: validationError })
  }

  const p = payload as ContactPayload

  // Guard: Lambda env vars not configured yet
  if (!EMAIL_USER || !EMAIL_APP_PASSWORD) {
    console.error('EMAIL_USER or EMAIL_APP_PASSWORD env vars are not set')
    return respond(500, {
      success: false,
      message: 'Mailer not configured. Please email me directly at abhix7435@gmail.com',
    })
  }

  // Send email
  try {
    await transporter.sendMail({
      from:    `"Abhishek | Portfolio" <${EMAIL_USER}>`,
      to:      OWNER_EMAIL,
      replyTo: p.email.trim(),
      subject: `[Portfolio] ${p.subject.trim()}`,
      html:    buildEmail(p),
      text:    `From: ${p.name.trim()} <${p.email.trim()}>\nSubject: ${p.subject.trim()}\n\n${p.message.trim()}`,
    })

    console.log(`[contact] Email sent — from: ${p.email} | subject: "${p.subject}"`)
    return respond(200, { success: true, message: 'Message sent. I\'ll be in touch soon!' })
  } catch (err) {
    console.error('[contact] Nodemailer error:', err)
    return respond(500, {
      success: false,
      message: 'Failed to send message. Please email me directly at abhix7435@gmail.com',
    })
  }
}
