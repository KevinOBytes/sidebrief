// backend/src/email.ts
import { Resend } from 'resend';
import nodemailer from 'nodemailer';

const FROM_EMAIL = process.env.EMAIL_FROM || 'Sidebrief <support@tkoresearch.com>';
const resendApiKey = process.env.RESEND_API_KEY || '';

const resendClient = resendApiKey ? new Resend(resendApiKey) : null;

// SMTP fallback configuration
const smtpHost = process.env.EMAIL_SMTP_HOST || '';
const smtpPort = parseInt(process.env.EMAIL_SMTP_PORT || '587', 10);
const smtpUser = process.env.EMAIL_ADDRESS || '';
const smtpPass = process.env.EMAIL_PASSWORD || '';

const smtpTransporter = (smtpHost && smtpUser)
  ? nodemailer.createTransport({
      host: smtpHost,
      port: smtpPort,
      secure: smtpPort === 465,
      auth: {
        user: smtpUser,
        pass: smtpPass,
      },
    })
  : null;

export interface SendEmailOptions {
  to: string;
  subject: string;
  html: string;
  text?: string;
}

/**
 * Sends an email via Resend, SMTP, or development logger.
 */
export async function sendEmail(options: SendEmailOptions): Promise<{ success: boolean; id?: string; provider: string }> {
  // 1. Try Resend if API key is present
  if (resendClient) {
    try {
      const { data, error } = await resendClient.emails.send({
        from: FROM_EMAIL,
        to: options.to,
        subject: options.subject,
        html: options.html,
        text: options.text,
      });

      if (error) {
        console.warn('[Email] Resend error:', error);
      } else {
        return { success: true, id: data?.id, provider: 'resend' };
      }
    } catch (err) {
      console.warn('[Email] Resend send exception:', err);
    }
  }

  // 2. Try SMTP if credentials are present
  if (smtpTransporter) {
    try {
      const info = await smtpTransporter.sendMail({
        from: FROM_EMAIL,
        to: options.to,
        subject: options.subject,
        html: options.html,
        text: options.text,
      });
      return { success: true, id: info.messageId, provider: 'smtp' };
    } catch (err) {
      console.warn('[Email] SMTP send exception:', err);
    }
  }

  // 3. Fallback / Sandbox logging
  console.log(`[Email Mock Sent] From: ${FROM_EMAIL} To: ${options.to} Subject: "${options.subject}"`);
  return { success: true, id: `mock-${Date.now()}`, provider: 'mock' };
}

/**
 * Sends the customer their Sidebrief Lifetime License Key with 1-click activation link.
 */
export async function sendLicenseKeyEmail(
  toEmail: string,
  licenseKey: string,
  appUrl: string = 'https://sidebrief.app'
): Promise<{ success: boolean; provider: string }> {
  const deepLink = `sidebrief://activate?key=${encodeURIComponent(licenseKey)}`;
  const downloadUrl = `${appUrl}/downloads/Sidebrief.dmg`;

  const html = `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background-color: #0b0c10; color: #f8fafc; margin: 0; padding: 40px 20px; }
    .container { max-width: 560px; margin: 0 auto; background: #151824; border: 1px solid rgba(255,255,255,0.1); border-radius: 16px; padding: 36px; }
    .logo { font-size: 24px; font-weight: 800; color: #6366f1; margin-bottom: 24px; letter-spacing: -0.02em; }
    h1 { font-size: 22px; margin-bottom: 12px; color: #ffffff; }
    p { font-size: 15px; line-height: 1.6; color: #94a3b8; }
    .key-box { background: rgba(0,0,0,0.4); border: 1px dashed #6366f1; border-radius: 10px; padding: 16px; margin: 24px 0; text-align: center; }
    .key-code { font-family: monospace; font-size: 20px; font-weight: bold; color: #818cf8; letter-spacing: 0.05em; }
    .btn { display: inline-block; background: #6366f1; color: #ffffff !important; text-decoration: none; padding: 14px 28px; border-radius: 10px; font-weight: 600; font-size: 15px; margin: 12px 0 24px; }
    .footer { font-size: 12px; color: #64748b; margin-top: 32px; border-top: 1px solid rgba(255,255,255,0.08); padding-top: 18px; }
    ol { color: #94a3b8; padding-left: 20px; font-size: 14px; line-height: 1.8; }
  </style>
</head>
<body>
  <div class="container">
    <div class="logo">Sidebrief</div>
    <h1>Your Lifetime License is Ready</h1>
    <p>Thank you for purchasing Sidebrief for macOS. Your license is valid for lifetime access on up to 3 personal Macs with all frontier models and free updates included.</p>

    <div class="key-box">
      <div style="font-size: 11px; text-transform: uppercase; color: #64748b; margin-bottom: 4px; font-weight: 700;">Your License Key</div>
      <div class="key-code">${licenseKey}</div>
    </div>

    <div style="text-align: center;">
      <a href="${deepLink}" class="btn">⚡ Activate in Sidebrief</a>
    </div>

    <p><strong>Quick Setup Instructions:</strong></p>
    <ol>
      <li>Download <a href="${downloadUrl}" style="color: #818cf8;">Sidebrief.dmg</a> and drag Sidebrief to your Applications folder.</li>
      <li>Click the <strong>Activate in Sidebrief</strong> button above, or paste your key into <em>Settings &rarr; License</em>.</li>
      <li>Grant ScreenCaptureKit and Microphone permissions when prompted.</li>
    </ol>

    <div class="footer">
      Sent from Sidebrief (tkoresearch.com) &bull; Questions? Reply to this email anytime.
    </div>
  </div>
</body>
</html>
  `;

  const text = `Your Sidebrief Lifetime License Key: ${licenseKey}\n\nActivate automatically: ${deepLink}\nDownload Sidebrief.dmg: ${downloadUrl}\n\nThank you for supporting Sidebrief!`;

  return sendEmail({
    to: toEmail,
    subject: 'Your Sidebrief for macOS License Key',
    html,
    text,
  });
}
