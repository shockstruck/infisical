import { TOrgPermission } from "@app/lib/types";
import { TEntitlementsResponse } from "@app/services/license-client/license-client-types";

export enum InstanceType {
  OnPrem = "self-hosted",
  // Self-hosted online license: features are resolved from License Server v2.
  EnterpriseOnPrem = "enterprise-self-hosted",
  EnterpriseOnPremOffline = "enterprise-self-hosted-offline",
  Cloud = "cloud"
}

export type TOfflineLicenseContents = {
  license: TOfflineLicense;
  signature: string;
};

export type TOfflineLicense = {
  issuedTo: string;
  licenseId: string;
  customerId: string | null;
  issuedAt: string;
  expiresAt: string | null;
  terminatesAt: string | null;
  // v1 (or absent) offline licenses carry the legacy feature-flag set directly; version 2 licenses
  // carry License Server v2 entitlements, which we project into the same feature shape.
  version?: number;
  features: TFeatureSet;
  entitlements?: TEntitlementsResponse;
};

export type TPlanNotice = {
  type: "trial_payment_failed";
  productKey: string;
  trialPlanKey: string | null;
  accessEndsAt: string;
  nextAttemptAt: string | null;
  cause: string | null;
};

export type TOrgSeatUsage = {
  membersUsed: number;
  identitiesUsed: number;
};

export type TFeatureSet = {
  _id: null;
  slug: string | null;
  productPlans?: {
    productKey: string;
    planKey: string | null;
    status: string | null;
    trialPlanKey: string | null;
    trialEndsAt: string | null;
  }[];
  notices?: TPlanNotice[];
  // True when features are sourced from an offline (air-gapped) license; the billing UI renders a
  // read-only offline banner instead of the live billing surface.
  isOffline?: boolean;
  tier: number;
  workspaceLimit: number | null;
  workspacesUsed: number;
  dynamicSecret: boolean;
  memberLimit: number | null;
  identityLimit: number | null;
  enforceIdentityLimit?: boolean;
  subOrganization: boolean;
  environmentLimit: number | null;
  environmentsUsed: number;
  secretVersioning: true;
  pitRecovery: boolean;
  ipAllowlisting: boolean;
  rbac: boolean;
  customAlerts: boolean;
  auditLogs: boolean;
  auditLogsRetentionDays: number | null;
  auditLogStreams: boolean;
  auditLogStreamLimit: number;
  githubOrgSync: boolean;
  samlSSO: boolean;
  enforceGoogleSSO: boolean;
  hsm: boolean;
  oidcSSO: boolean;
  secretAccessInsights: boolean;
  scim: boolean;
  ldap: boolean;
  groups: boolean;
  status: null;
  trial_end: null;
  has_used_trial: boolean;
  secretApproval: boolean;
  secretRotation: boolean;
  instanceUserManagement: boolean;
  externalKms: boolean;
  rateLimits: {
    readLimit: number;
    writeLimit: number;
    secretsLimit: number;
  };
  kmsPqc: boolean;
  enforceMfa: boolean;
  projectTemplates: boolean;
  kmip: boolean;
  gateway: boolean;
  gatewayPool: boolean;
  pamEnterpriseAlerting: boolean;
  secretScanning: boolean;
  enterpriseSecretSyncs: boolean;
  enterpriseAppConnections: boolean;
  machineIdentityAuthTemplates: boolean;
  fips: boolean;
  eventSubscriptions: boolean;
  secretShareExternalBranding: boolean;
  honeyTokens: boolean;
  honeyTokenLimit: number;
  secretsBrokering: boolean;
  agentVaultByoS3: boolean;
  agentVaultManagedStorage: boolean;
  agentVaultSessionLogRetentionDays: number | null;
  secretSyncLimit: null;
  maxPamAccounts: null;

  // PKI / Cert Manager
  pkiAcme: boolean;
  pkiEst: boolean;
  pkiScep: boolean;
  pkiPqc: boolean;
  // caCrl defaults on, so self-hosted OSS keeps it; the License Server's free-plan default is what
  // withholds it on cloud.
  caCrl: boolean;
  pkiOcsp: boolean;
  pkiAwsKmsSigning: boolean;
  pkiEnterpriseCaIntegrations: boolean;
  pkiExternalIntermediateCa: boolean;
  pkiDiscovery: boolean;
  pkiEnterpriseAlerting: boolean;
  pkiApprovals: boolean;
  pkiSyncs: boolean;
  pkiLegacyTemplates: boolean;
  pkiCodeSigning: boolean;
  // maxCas covers every CA type, maxInternalCas covers INTERNAL only. Both enforced, whichever binds
  // first. Typed number | null rather than the literal null the flags above use, so consumers can
  // name the limit in an error without casting.
  maxCas: number | null;
  maxInternalCas: number | null;
  maxCertificates: number | null;
  // Wildcards have no separate boolean gate: 0 means the plan does not include them at all, which is
  // how the free tier withholds them. A wildcard certificate counts against maxCertificates too.
  maxWildcardCertificates: number | null;
  maxSansPerCertificate: number | null;

  pam: null;
  certManager: null;
  secretsTemporaryAccess: null;
  enterprisePamAccount: null;
  crossProjectSecretSharing: boolean;
  secretsFolderRbac: boolean;
};

export type TOrgPlanDTO = {
  projectId?: string;
  refreshCache?: boolean;
  rootOrgId: string;
} & TOrgPermission;

export enum LicenseType {
  Offline = "offline",
  // Self-hosted online license key; resolves entitlements from License Server v2.
  Online = "online"
}

export type TLicenseKeyConfig =
  | {
      isValid: false;
    }
  | {
      isValid: true;
      licenseKey: string;
      type: LicenseType;
    };
