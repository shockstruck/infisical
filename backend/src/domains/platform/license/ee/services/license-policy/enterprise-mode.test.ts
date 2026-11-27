import { TInstanceFeatures } from "../../../ce/models/instance-entitlements";
import { Plan, PlanFeature, PlanLimit, PlanProduct } from "../../../ce/models/plan";
import { getInstanceEnterpriseModeFeatures } from "./enterprise-mode";
import { communityFeatures } from "./entitlement-projection";

const expected: TInstanceFeatures = {
  _id: null,
  slug: "enterprise",
  tier: -1,
  workspaceLimit: null,
  workspacesUsed: 0,
  memberLimit: null,
  identityLimit: null,
  enforceIdentityLimit: false,
  environmentLimit: null,
  environmentsUsed: 0,
  dynamicSecret: true,
  subOrganization: true,
  secretVersioning: true,
  pitRecovery: true,
  ipAllowlisting: true,
  rbac: true,
  customAlerts: true,
  auditLogs: true,
  auditLogsRetentionDays: 36500,
  auditLogStreams: true,
  auditLogStreamLimit: Number.MAX_SAFE_INTEGER,
  githubOrgSync: true,
  samlSSO: true,
  enforceGoogleSSO: true,
  hsm: true,
  oidcSSO: true,
  secretAccessInsights: true,
  scim: true,
  ldap: true,
  groups: true,
  status: null,
  trial_end: null,
  has_used_trial: true,
  secretApproval: true,
  secretRotation: true,
  externalKms: true,
  rateLimits: { readLimit: 60, writeLimit: 200, secretsLimit: 40 },
  kmsPqc: true,
  enforceMfa: true,
  projectTemplates: true,
  kmip: true,
  gateway: true,
  gatewayPool: true,
  pamEnterpriseAlerting: true,
  secretScanning: true,
  enterpriseSecretSyncs: true,
  enterpriseAppConnections: true,
  machineIdentityAuthTemplates: true,
  eventSubscriptions: true,
  secretShareExternalBranding: true,
  honeyTokens: true,
  honeyTokenLimit: Number.MAX_SAFE_INTEGER,
  secretsBrokering: true,
  agentVaultByoS3: true,
  agentVaultManagedStorage: true,
  agentVaultSessionLogRetentionDays: 30,
  agentVaultHooks: true,
  secretSyncLimit: null,
  maxPamAccounts: null,
  pkiAcme: true,
  pkiEst: true,
  pkiScep: true,
  pkiMicrosoftAutoenrollment: true,
  pkiPqc: true,
  caCrl: true,
  pkiOcsp: true,
  pkiAwsKmsSigning: true,
  pkiEnterpriseCaIntegrations: true,
  pkiExternalIntermediateCa: true,
  pkiCrossSignedCa: true,
  pkiDiscovery: true,
  pkiEnterpriseAlerting: true,
  pkiApprovals: true,
  pkiSyncs: true,
  pkiLegacyTemplates: true,
  pkiCodeSigning: true,
  maxCas: null,
  maxInternalCas: null,
  maxCertificates: null,
  maxWildcardCertificates: null,
  maxSansPerCertificate: null,
  pam: null,
  agentVault: null,
  certManager: null,
  secretsTemporaryAccess: null,
  enterprisePamAccount: null,
  crossProjectSecretSharing: true,
  secretsFolderRbac: true,
  fips: true,
  instanceUserManagement: true
};

describe("getInstanceEnterpriseModeFeatures", () => {
  test("defines the approved value for every instance feature", () => {
    expect(getInstanceEnterpriseModeFeatures()).toStrictEqual(expected);
  });

  test("enables every plan feature and leaves limits and products unrestricted", () => {
    const plan = Plan.restore(getInstanceEnterpriseModeFeatures());
    Object.values(PlanFeature).forEach((feature) => expect(plan.has(feature), feature).toBe(true));
    Object.values(PlanLimit).forEach((limit) => expect(plan.exceeds(limit, 1_000_000), limit).toBe(false));
    const features = plan.toJSON();
    Object.values(PlanProduct).forEach((product) => expect(features[product], product).toBeNull());
  });

  test("does not mutate community defaults", () => {
    const defaults = communityFeatures();
    const original = structuredClone(defaults);

    getInstanceEnterpriseModeFeatures();

    expect(defaults).toStrictEqual(original);
    expect(communityFeatures()).toStrictEqual(original);
    expect(defaults).toMatchObject({ slug: null, rbac: false, maxCas: 1, agentVaultManagedStorage: false });
  });
});
