// backend/src/licensing.ts
import crypto from 'crypto';
import Stripe from 'stripe';
import { query } from './db.js';
import { sendLicenseKeyEmail } from './email.js';

const stripeSecretKey = process.env.STRIPE_SECRET_KEY || '';
const stripeWebhookSecret = process.env.STRIPE_WEBHOOK_SECRET || '';

export const stripe = stripeSecretKey
  ? new Stripe(stripeSecretKey, { apiVersion: '2025-01-27.acacia' as any })
  : null;

/**
 * Generates a formatted cryptographic license key.
 * Format: SB-XXXX-XXXX-XXXX-XXXX
 */
export function generateLicenseKey(): string {
  const bytes = crypto.randomBytes(8).toString('hex').toUpperCase();
  const chunk1 = bytes.slice(0, 4);
  const chunk2 = bytes.slice(4, 8);
  const chunk3 = bytes.slice(8, 12);
  const chunk4 = bytes.slice(12, 16);
  return `SB-${chunk1}-${chunk2}-${chunk3}-${chunk4}`;
}

export interface LicenseRecord {
  id: string;
  license_key: string;
  email: string;
  stripe_session_id?: string;
  stripe_customer_id?: string;
  status: 'active' | 'revoked' | 'expired';
  hardware_uuid?: string;
  machine_name?: string;
  last_ip?: string;
  use_count?: number;
  activated_at?: string;
  last_used_at?: string;
  created_at: string;
}

/**
 * Creates a Stripe Checkout Session for a one-time $19.99 purchase.
 */
export async function createCheckoutSession(options: {
  email?: string;
  successUrl: string;
  cancelUrl: string;
}): Promise<{ url: string; sessionId?: string; mockKey?: string }> {
  if (!stripe) {
    // Development fallback if Stripe API keys are not yet configured in .env
    const mockKey = generateLicenseKey();
    const id = crypto.randomUUID();
    const email = options.email || 'customer@example.com';

    try {
      // 1. Provision user account if not exists
      const userId = crypto.randomUUID();
      await query(
        `INSERT INTO users (id, email, name)
         VALUES ($1, $2, $3)
         ON CONFLICT (email) DO NOTHING`,
        [userId, email, email.split('@')[0]]
      );

      // 2. Insert license
      await query(
        `INSERT INTO licenses (id, license_key, email, stripe_session_id, status)
         VALUES ($1, $2, $3, $4, 'active')
         ON CONFLICT (license_key) DO NOTHING`,
        [id, mockKey, email, 'mock_session_' + Date.now()]
      );

      // 3. Send email from tkoresearch.com with license key
      await sendLicenseKeyEmail(email, mockKey);
    } catch (e) {
      console.warn('[Licensing] Could not write mock license to DB (continuing in-memory):', e);
    }

    const redirectUrl = new URL(options.successUrl);
    redirectUrl.searchParams.set('session_id', 'mock_session_' + Date.now());
    redirectUrl.searchParams.set('key', mockKey);
    redirectUrl.searchParams.set('mock', 'true');

    return {
      url: redirectUrl.toString(),
      sessionId: 'mock_session_' + Date.now(),
      mockKey,
    };
  }

  const session = await stripe.checkout.sessions.create({
    payment_method_types: ['card'],
    mode: 'payment',
    customer_email: options.email,
    line_items: [
      {
        price_data: {
          currency: 'usd',
          unit_amount: 1999, // $19.99 USD
          product_data: {
            name: 'Sidebrief for macOS - Lifetime License',
            description:
              'Native macOS dual-audio meeting copilot with instant local transcription, privacy-first encrypted storage, and real-time AI assistance.',
            images: ['https://sidebrief.app/icon.png'],
          },
        },
        quantity: 1,
      },
    ],
    success_url: `${options.successUrl}?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: options.cancelUrl,
  });

  return {
    url: session.url || options.successUrl,
    sessionId: session.id,
  };
}

/**
 * Handles Stripe webhook completion event, registers the license key,
 * auto-provisions the user account, and sends the license email via tkoresearch.com.
 */
export async function handleStripeWebhook(
  rawBody: string | Buffer,
  sigHeader: string
): Promise<{ success: boolean; licenseKey?: string; email?: string }> {
  let event: Stripe.Event;

  if (stripe && stripeWebhookSecret) {
    event = stripe.webhooks.constructEvent(rawBody, sigHeader, stripeWebhookSecret);
  } else {
    try {
      event = typeof rawBody === 'string' ? JSON.parse(rawBody) : JSON.parse(rawBody.toString('utf8'));
    } catch {
      throw new Error('Invalid webhook payload format');
    }
  }

  if (event.type === 'checkout.session.completed') {
    const session = event.data.object as Stripe.Checkout.Session;
    const email = session.customer_details?.email || session.customer_email || 'unknown@example.com';
    const sessionId = session.id;
    const customerId = (session.customer as string) || null;

    const licenseKey = generateLicenseKey();
    const id = crypto.randomUUID();
    const userId = crypto.randomUUID();

    // 1. Auto-provision user account
    await query(
      `INSERT INTO users (id, email, name)
       VALUES ($1, $2, $3)
       ON CONFLICT (email) DO NOTHING`,
      [userId, email, session.customer_details?.name || email.split('@')[0]]
    );

    // 2. Insert license
    await query(
      `INSERT INTO licenses (id, license_key, email, stripe_session_id, stripe_customer_id, status)
       VALUES ($1, $2, $3, $4, $5, 'active')
       ON CONFLICT (license_key) DO NOTHING`,
      [id, licenseKey, email, sessionId, customerId]
    );

    // 3. Send email from tkoresearch.com
    await sendLicenseKeyEmail(email, licenseKey);

    return { success: true, licenseKey, email };
  }

  return { success: true };
}

/**
 * Activates a license key for a given client machine hardware UUID,
 * recording IP address, machine name, and audit log.
 */
export async function activateLicense(options: {
  licenseKey: string;
  hardwareUuid: string;
  machineName?: string;
  ipAddress?: string;
  userAgent?: string;
  email?: string;
}): Promise<{ valid: boolean; email?: string; message: string; activatedAt?: string }> {
  const cleanKey = options.licenseKey.trim().toUpperCase();
  if (!cleanKey) {
    return { valid: false, message: 'License key is required' };
  }

  const rows = await query<LicenseRecord>(
    `SELECT * FROM licenses WHERE license_key = $1 LIMIT 1`,
    [cleanKey]
  );

  if (!rows || rows.length === 0) {
    return { valid: false, message: 'License key not found. Please verify and try again.' };
  }

  const license = rows[0];
  if (license.status !== 'active') {
    return { valid: false, message: `License is ${license.status}. Please contact support.` };
  }

  const now = new Date().toISOString();
  const logId = crypto.randomUUID();

  // 1. Record usage audit log
  await query(
    `INSERT INTO license_usage_logs (id, license_id, license_key, hardware_uuid, machine_name, ip_address, user_agent, action)
     VALUES ($1, $2, $3, $4, $5, $6, $7, 'activate')`,
    [
      logId,
      license.id,
      cleanKey,
      options.hardwareUuid || 'UNKNOWN_HWID',
      options.machineName || null,
      options.ipAddress || null,
      options.userAgent || null,
    ]
  );

  // 2. Update license record with device and IP metadata
  await query(
    `UPDATE licenses
     SET hardware_uuid = $1,
         machine_name = COALESCE($2, machine_name),
         last_ip = $3,
         last_used_at = NOW(),
         use_count = use_count + 1,
         activated_at = COALESCE(activated_at, NOW()),
         updated_at = NOW()
     WHERE id = $4`,
    [
      options.hardwareUuid || null,
      options.machineName || null,
      options.ipAddress || null,
      license.id,
    ]
  );

  return {
    valid: true,
    email: license.email,
    message: 'License successfully activated',
    activatedAt: license.activated_at || now,
  };
}

/**
 * Validates a license key and audits the request IP and machine identifier.
 */
export async function validateLicense(options: {
  licenseKey: string;
  hardwareUuid?: string;
  machineName?: string;
  ipAddress?: string;
  userAgent?: string;
}): Promise<{ valid: boolean; status: string; email?: string }> {
  const cleanKey = options.licenseKey.trim().toUpperCase();
  const rows = await query<LicenseRecord>(
    `SELECT * FROM licenses WHERE license_key = $1 LIMIT 1`,
    [cleanKey]
  );

  if (!rows || rows.length === 0) {
    return { valid: false, status: 'not_found' };
  }

  const lic = rows[0];
  const isValid = lic.status === 'active';

  // Audit validation ping
  if (options.hardwareUuid || options.ipAddress) {
    const logId = crypto.randomUUID();
    await query(
      `INSERT INTO license_usage_logs (id, license_id, license_key, hardware_uuid, machine_name, ip_address, user_agent, action)
       VALUES ($1, $2, $3, $4, $5, $6, $7, 'validate')`,
      [
        logId,
        lic.id,
        cleanKey,
        options.hardwareUuid || 'UNKNOWN_HWID',
        options.machineName || null,
        options.ipAddress || null,
        options.userAgent || null,
      ]
    );

    // Update last ping time
    await query(
      `UPDATE licenses
       SET last_ip = COALESCE($1, last_ip),
           last_used_at = NOW(),
           use_count = use_count + 1
       WHERE id = $2`,
      [options.ipAddress || null, lic.id]
    );
  }

  return {
    valid: isValid,
    status: lic.status,
    email: lic.email,
  };
}

/**
 * Handles user account login / key recovery by sending a magic link email.
 */
export async function requestMagicLink(email: string): Promise<{ success: boolean; count: number; message: string }> {
  const cleanEmail = email.trim().toLowerCase();
  if (!cleanEmail || !cleanEmail.includes('@')) {
    return { success: false, count: 0, message: 'Invalid email address.' };
  }

  const rows = await query<LicenseRecord>(
    `SELECT * FROM licenses WHERE LOWER(email) = $1 AND status = 'active' ORDER BY created_at DESC`,
    [cleanEmail]
  );

  if (!rows || rows.length === 0) {
    // If no license found, inform the user
    return {
      success: true,
      count: 0,
      message: 'If an active license exists for this email, an activation link has been sent.',
    };
  }

  const primaryLicense = rows[0];
  await sendLicenseKeyEmail(cleanEmail, primaryLicense.license_key);

  return {
    success: true,
    count: rows.length,
    message: `We sent your license key and instant activation link to ${cleanEmail}. Check your inbox!`,
  };
}
