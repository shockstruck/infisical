import axios, { AxiosError } from "axios";

import { TLicenseServiceFactory } from "@app/ee/services/license/license-service";
import { getConfig, TEnvConfig } from "@app/lib/config/env";
import { request } from "@app/lib/config/request";
import { BadRequestError } from "@app/lib/errors";
import { logger } from "@app/lib/logger";
import { UserAliasType } from "@app/services/user-alias/user-alias-types";

import { LicenseType, TFeatureSet, TLicenseKeyConfig, TOfflineLicenseContents } from "./license-types";

export const isOfflineLicenseKey = (licenseKey: string): boolean => {
  try {
    const contents = JSON.parse(Buffer.from(licenseKey, "base64").toString("utf8")) as TOfflineLicenseContents;

    return "signature" in contents && "license" in contents;
  } catch (error) {
    return false;
  }
};

// Self-hosted License Server v2 keys carry this prefix; legacy online keys look like "QVHK-HIGYH".
export const SELF_HOSTED_V2_LICENSE_KEY_PREFIX = "infisical_lk_";

export const isV2SelfHostedLicenseKey = (licenseKey: string): boolean =>
  licenseKey.startsWith(SELF_HOSTED_V2_LICENSE_KEY_PREFIX);

export const getLicenseKeyConfig = (
  config?: Pick<TEnvConfig, "LICENSE_KEY" | "LICENSE_KEY_OFFLINE">
): TLicenseKeyConfig => {
  const cfg = config || getConfig();

  if (!cfg) {
    return { isValid: false };
  }

  const licenseKey = cfg.LICENSE_KEY;

  if (licenseKey) {
    if (isV2SelfHostedLicenseKey(licenseKey)) {
      return { isValid: true, licenseKey, type: LicenseType.OnlineV2 };
    }

    if (isOfflineLicenseKey(licenseKey)) {
      return { isValid: true, licenseKey, type: LicenseType.Offline };
    }

    return { isValid: true, licenseKey, type: LicenseType.Online };
  }

  const offlineLicenseKey = cfg.LICENSE_KEY_OFFLINE;

  // backwards compatibility
  if (offlineLicenseKey) {
    if (isOfflineLicenseKey(offlineLicenseKey)) {
      return { isValid: true, licenseKey: offlineLicenseKey, type: LicenseType.Offline };
    }

    return { isValid: false };
  }

  return { isValid: false };
};

export const getDefaultOnPremFeatures = (): TFeatureSet => ({
  _id: null,
  slug: null,
  tier: -1,
  workspaceLimit: null,
  workspacesUsed: 0,
  memberLimit: null,
  membersUsed: 0,
  environmentLimit: null,
  environmentsUsed: 0,
  identityLimit: null,
  identitiesUsed: 0,
  dynamicSecret: false,
  secretVersioning: true,
  pitRecovery: false,
  ipAllowlisting: false,
  rbac: false,
  githubOrgSync: false,
  customRateLimits: false,
  subOrganization: false,
  customAlerts: false,
  secretAccessInsights: false,
  auditLogs: false,
  auditLogsRetentionDays: 0,
  auditLogStreams: false,
  auditLogStreamLimit: 3,
  samlSSO: false,
  enforceGoogleSSO: false,
  hsm: false,
  oidcSSO: false,
  scim: false,
  ldap: false,
  groups: false,
  status: null,
  trial_end: null,
  has_used_trial: true,
  secretApproval: false,
  secretRotation: false,
  caCrl: false,
  instanceUserManagement: false,
  externalKms: false,
  rateLimits: {
    readLimit: 60,
    writeLimit: 200,
    secretsLimit: 40
  },
  pkiEst: false,
  pkiAcme: true,
  pkiScep: false,
  pkiPqc: false,
  kmsPqc: false,
  enforceMfa: false,
  projectTemplates: false,
  kmip: false,
  gateway: false,
  gatewayPool: false,
  pamSlackNotifications: false,
  sshHostGroups: false,
  secretScanning: false,
  enterpriseSecretSyncs: false,
  enterpriseCertificateSyncs: false,
  enterpriseAppConnections: false,
  fips: false,
  eventSubscriptions: false,
  machineIdentityAuthTemplates: false,
  pkiLegacyTemplates: false,
  secretShareExternalBranding: false,
  honeyTokens: false,
  honeyTokenLimit: 0,
  secretsBrokering: true
});

// Fork customization (self-hosted Enterprise Mode): pure self-hosted instances — no cloud license
// server key and no license key — run with every enterprise/paid capability unlocked and no upgrade
// gating or upsell. This is applied ONLY when the instance resolves to InstanceType.OnPrem (see the
// OSS fallthrough in license-service `init()`); cloud and licensed on-prem instances are untouched,
// and getDefaultOnPremFeatures() still seeds the cloud/v2 entitlement projection so cloud gating and
// the cloud error-fallback keep their free/paid behavior.
//
// Only capability flags are enabled — policy/enforcement flags (enforceMfa, enforceGoogleSSO) merely
// unlock the *ability* to enforce; the actual enforcement stays admin-controlled on the org record,
// so nothing is forced on. Limits are set to unlimited (null) or an effectively-unlimited finite
// value where the consuming code has no null sentinel (audit log retention/stream count).
export const getInstanceEnterpriseModeFeatures = (): TFeatureSet => ({
  ...getDefaultOnPremFeatures(),
  slug: "enterprise",
  dynamicSecret: true,
  pitRecovery: true,
  ipAllowlisting: true,
  rbac: true,
  githubOrgSync: true,
  customRateLimits: true,
  subOrganization: true,
  customAlerts: true,
  secretAccessInsights: true,
  auditLogs: true,
  // 0 disables audit-log persistence entirely; use an effectively-unlimited (~100y) retention window.
  auditLogsRetentionDays: 36500,
  auditLogStreams: true,
  auditLogStreamLimit: Number.MAX_SAFE_INTEGER,
  samlSSO: true,
  enforceGoogleSSO: true,
  hsm: true,
  oidcSSO: true,
  scim: true,
  ldap: true,
  groups: true,
  secretApproval: true,
  secretRotation: true,
  caCrl: true,
  instanceUserManagement: true,
  externalKms: true,
  pkiEst: true,
  pkiAcme: true,
  pkiScep: true,
  pkiPqc: true,
  kmsPqc: true,
  enforceMfa: true,
  projectTemplates: true,
  kmip: true,
  gateway: true,
  gatewayPool: true,
  pamSlackNotifications: true,
  sshHostGroups: true,
  secretScanning: true,
  enterpriseSecretSyncs: true,
  enterpriseCertificateSyncs: true,
  enterpriseAppConnections: true,
  fips: true,
  eventSubscriptions: true,
  machineIdentityAuthTemplates: true,
  pkiLegacyTemplates: true,
  secretShareExternalBranding: true,
  honeyTokens: true,
  // No null "unlimited" sentinel here: the /limits route returns limit as z.number(), so use an
  // effectively-unlimited finite value instead of null.
  honeyTokenLimit: Number.MAX_SAFE_INTEGER,
  secretsBrokering: true
});

export const setupLicenseRequestWithStore = (
  baseURL: string,
  refreshUrl: string,
  licenseKey: string,
  region?: string
) => {
  let token: string;
  const licenseReq = axios.create({
    baseURL,
    timeout: 35 * 1000,
    headers: {
      "x-region": region
    }
  });

  const refreshLicense = async () => {
    const appCfg = getConfig();
    const {
      data: { token: authToken }
    } = await request.post<{ token: string }>(
      refreshUrl,
      {},
      {
        baseURL: appCfg.LICENSE_SERVER_URL,
        headers: {
          "X-API-KEY": licenseKey
        }
      }
    );
    token = authToken;
    return token;
  };

  licenseReq.interceptors.request.use(
    (config) => {
      if (token && config.headers) {
        // eslint-disable-next-line no-param-reassign
        config.headers.Authorization = `Bearer ${token}`;
      }
      return config;
    },
    (err) => Promise.reject(err)
  );

  licenseReq.interceptors.response.use(
    (response) => response,
    async (err) => {
      const originalRequest = (err as AxiosError).config;
      const errStatusCode = Number((err as AxiosError)?.response?.status);
      logger.error((err as AxiosError)?.response?.data, "License server call error");
      // eslint-disable-next-line
      if ((errStatusCode === 401 || errStatusCode === 403) && !(originalRequest as any)._retry) {
        // eslint-disable-next-line
        (originalRequest as any)._retry = true; // injected

        // refresh
        await refreshLicense();

        licenseReq.defaults.headers.common.Authorization = `Bearer ${token}`;
        return licenseReq(originalRequest!);
      }

      return Promise.reject(err);
    }
  );

  return { request: licenseReq, refreshLicense };
};

export const throwOnPlanSeatLimitReached = async (
  licenseService: Pick<TLicenseServiceFactory, "getPlan">,
  orgId: string,
  type?: UserAliasType
) => {
  const plan = await licenseService.getPlan(orgId);
  const isEnterpriseBypass = plan?.slug === "enterprise" && !plan?.enforceIdentityLimit;

  if (!isEnterpriseBypass && plan?.identityLimit && plan.identitiesUsed >= plan.identityLimit) {
    // limit imposed on number of identities allowed / number of identities used exceeds the number of identities allowed
    throw new BadRequestError({
      message: `Failed to create new member${type ? ` via ${type.toUpperCase()}` : ""} due to member limit reached. Upgrade plan to add more members.`
    });
  }
};
