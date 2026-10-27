import { Knex } from "knex";

import { TLicenseServiceFactory } from "@app/ee/services/license/license-service";
import { getConfig, TEnvConfig } from "@app/lib/config/env";
import { BadRequestError } from "@app/lib/errors";
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

export const getLicenseKeyConfig = (
  config?: Pick<TEnvConfig, "LICENSE_KEY" | "LICENSE_KEY_OFFLINE">
): TLicenseKeyConfig => {
  const cfg = config || getConfig();

  if (!cfg) {
    return { isValid: false };
  }

  const licenseKey = cfg.LICENSE_KEY;

  if (licenseKey) {
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
  dynamicSecret: false,
  memberLimit: null,
  identityLimit: null,
  subOrganization: false,
  environmentLimit: null,
  environmentsUsed: 0,
  secretVersioning: true,
  pitRecovery: false,
  ipAllowlisting: false,
  rbac: false,
  customAlerts: false,
  auditLogs: false,
  auditLogsRetentionDays: 0,
  auditLogStreams: false,
  auditLogStreamLimit: 3,
  githubOrgSync: false,
  samlSSO: false,
  enforceGoogleSSO: false,
  hsm: false,
  oidcSSO: false,
  secretAccessInsights: false,
  scim: false,
  ldap: false,
  groups: false,
  status: null,
  trial_end: null,
  has_used_trial: true,
  secretApproval: false,
  secretRotation: false,
  instanceUserManagement: false,
  externalKms: false,
  rateLimits: {
    readLimit: 60,
    writeLimit: 200,
    secretsLimit: 40
  },
  kmsPqc: false,
  enforceMfa: false,
  projectTemplates: false,
  kmip: false,
  gateway: false,
  gatewayPool: false,
  pamEnterpriseAlerting: false,
  secretScanning: false,
  enterpriseSecretSyncs: false,
  enterpriseAppConnections: false,
  machineIdentityAuthTemplates: false,
  fips: false,
  eventSubscriptions: false,
  secretShareExternalBranding: false,
  honeyTokens: false,
  honeyTokenLimit: 0,
  secretsBrokering: true,
  agentVaultByoS3: false,
  // On by default, like secretsBrokering, until the License Server sets it per plan.
  agentVaultManagedStorage: true,
  agentVaultSessionLogRetentionDays: 30,
  secretSyncLimit: null,
  maxPamAccounts: null,
  // PKI / Cert Manager
  pkiAcme: true,
  pkiEst: false,
  pkiScep: false,
  pkiPqc: false,
  caCrl: true,
  pkiOcsp: false,
  pkiAwsKmsSigning: false,
  pkiEnterpriseCaIntegrations: false,
  pkiExternalIntermediateCa: false,
  pkiDiscovery: false,
  pkiEnterpriseAlerting: false,
  pkiApprovals: false,
  pkiSyncs: false,
  pkiLegacyTemplates: false,
  pkiCodeSigning: false,
  maxCas: 1,
  maxInternalCas: null,
  maxCertificates: null,
  maxWildcardCertificates: null,
  maxSansPerCertificate: null,
  // product gating
  pam: null,
  certManager: null,
  secretsTemporaryAccess: null,
  enterprisePamAccount: null,
  crossProjectSecretSharing: false,
  secretsFolderRbac: false
});

export const getInstanceEnterpriseModeFeatures = (): TFeatureSet => ({
  ...getDefaultOnPremFeatures(),
  slug: "enterprise",
  dynamicSecret: true,
  pitRecovery: true,
  ipAllowlisting: true,
  rbac: true,
  githubOrgSync: true,
  subOrganization: true,
  customAlerts: true,
  secretAccessInsights: true,
  auditLogs: true,
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
  pkiOcsp: true,
  pkiEnterpriseCaIntegrations: true,
  pkiExternalIntermediateCa: true,
  pkiDiscovery: true,
  pkiEnterpriseAlerting: true,
  pkiApprovals: true,
  pkiSyncs: true,
  pkiCodeSigning: true,
  maxCas: null,
  kmsPqc: true,
  enforceMfa: true,
  enforceIdentityLimit: false,
  projectTemplates: true,
  kmip: true,
  gateway: true,
  gatewayPool: true,
  pamEnterpriseAlerting: true,
  secretScanning: true,
  enterpriseSecretSyncs: true,
  enterpriseAppConnections: true,
  fips: true,
  eventSubscriptions: true,
  machineIdentityAuthTemplates: true,
  pkiLegacyTemplates: true,
  secretShareExternalBranding: true,
  honeyTokens: true,
  honeyTokenLimit: Number.MAX_SAFE_INTEGER,
  secretsBrokering: true,
  agentVaultByoS3: true,
  crossProjectSecretSharing: true,
  secretsFolderRbac: true
});

export const getEnforcedIdentityLimit = (plan: TFeatureSet): number | null => {
  const isEnterpriseBypass = plan?.slug === "enterprise" && !plan?.enforceIdentityLimit;
  if (isEnterpriseBypass) return null;
  return plan?.identityLimit ?? null;
};

export const throwOnPlanSeatLimitReached = async ({
  licenseService,
  orgId,
  identityLimit,
  tx,
  aliasType
}: {
  licenseService: Pick<TLicenseServiceFactory, "getOrgSeatUsage">;
  orgId: string;
  identityLimit: number | null;
  tx: Knex;
  aliasType?: UserAliasType;
}) => {
  if (!identityLimit) return;

  const { identitiesUsed } = await licenseService.getOrgSeatUsage(orgId, tx);
  if (identitiesUsed >= identityLimit) {
    // limit imposed on number of identities allowed / number of identities used exceeds the number of identities allowed
    throw new BadRequestError({
      message: `Failed to create new member${aliasType ? ` via ${aliasType.toUpperCase()}` : ""} due to member limit reached. Upgrade plan to add more members.`
    });
  }
};
