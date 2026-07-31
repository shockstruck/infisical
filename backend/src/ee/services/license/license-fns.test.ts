import { describe, expect, test } from "vitest";

import { getDefaultOnPremFeatures, getInstanceEnterpriseModeFeatures } from "./license-fns";
import { TFeatureSet } from "./license-types";

const EXPECTED_ENTERPRISE_FEATURES: TFeatureSet = {
  _id: null,
  slug: "enterprise",
  tier: -1,
  workspaceLimit: null,
  workspacesUsed: 0,
  secretSyncLimit: null,
  maxInternalCas: null,
  maxPamAccounts: null,
  memberLimit: null,
  membersUsed: 0,
  environmentLimit: null,
  environmentsUsed: 0,
  identityLimit: null,
  identitiesUsed: 0,
  enforceIdentityLimit: false,
  dynamicSecret: true,
  secretVersioning: true,
  pitRecovery: true,
  ipAllowlisting: true,
  rbac: true,
  githubOrgSync: true,
  customRateLimits: true,
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
  status: null,
  trial_end: null,
  has_used_trial: true,
  secretApproval: true,
  secretRotation: true,
  caCrl: true,
  instanceUserManagement: true,
  externalKms: true,
  rateLimits: {
    readLimit: 60,
    writeLimit: 200,
    secretsLimit: 40
  },
  pkiEst: true,
  pkiAcme: true,
  pkiScep: true,
  pkiPqc: true,
  pkiCodeSigning: null,
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
  honeyTokenLimit: Number.MAX_SAFE_INTEGER,
  secretsBrokering: true,
  pam: null,
  certManager: null,
  secretsTemporaryAccess: null,
  enterprisePamAccount: null
};

describe("getInstanceEnterpriseModeFeatures", () => {
  test("defines the approved value for every TFeatureSet field", () => {
    expect(getInstanceEnterpriseModeFeatures()).toStrictEqual(EXPECTED_ENTERPRISE_FEATURES);
  });

  test("keeps all eight new v0.162.15 product fields unrestricted", () => {
    const plan = getInstanceEnterpriseModeFeatures();

    expect({
      secretSyncLimit: plan.secretSyncLimit,
      maxInternalCas: plan.maxInternalCas,
      maxPamAccounts: plan.maxPamAccounts,
      pkiCodeSigning: plan.pkiCodeSigning,
      pam: plan.pam,
      certManager: plan.certManager,
      secretsTemporaryAccess: plan.secretsTemporaryAccess,
      enterprisePamAccount: plan.enterprisePamAccount
    }).toStrictEqual({
      secretSyncLimit: null,
      maxInternalCas: null,
      maxPamAccounts: null,
      pkiCodeSigning: null,
      pam: null,
      certManager: null,
      secretsTemporaryAccess: null,
      enterprisePamAccount: null
    });
  });

  test("does not mutate the free plan used by cloud and licensed projections", () => {
    getInstanceEnterpriseModeFeatures();

    expect(getDefaultOnPremFeatures()).toMatchObject({
      slug: null,
      rbac: false,
      samlSSO: false,
      auditLogs: false,
      honeyTokenLimit: 0
    });
  });
});
