import { getDefaultOnPremFeatures, getInstanceEnterpriseModeFeatures } from "./license-fns";
import { TFeatureSet } from "./license-types";

// Capability flags that the free OSS default keeps disabled but self-hosted Enterprise Mode unlocks.
const ENTERPRISE_CAPABILITY_FLAGS: (keyof TFeatureSet)[] = [
  "dynamicSecret",
  "pitRecovery",
  "ipAllowlisting",
  "rbac",
  "githubOrgSync",
  "customRateLimits",
  "subOrganization",
  "customAlerts",
  "secretAccessInsights",
  "auditLogs",
  "auditLogStreams",
  "samlSSO",
  "enforceGoogleSSO",
  "hsm",
  "oidcSSO",
  "scim",
  "ldap",
  "groups",
  "secretApproval",
  "secretRotation",
  "caCrl",
  "instanceUserManagement",
  "externalKms",
  "pkiEst",
  "pkiScep",
  "pkiPqc",
  "kmsPqc",
  "enforceMfa",
  "projectTemplates",
  "kmip",
  "gateway",
  "gatewayPool",
  "pamSlackNotifications",
  "sshHostGroups",
  "secretScanning",
  "enterpriseSecretSyncs",
  "enterpriseCertificateSyncs",
  "enterpriseAppConnections",
  "machineIdentityAuthTemplates",
  "pkiLegacyTemplates",
  "fips",
  "eventSubscriptions",
  "secretShareExternalBranding",
  "honeyTokens"
];

describe("getInstanceEnterpriseModeFeatures", () => {
  test("marks the plan as enterprise", () => {
    expect(getInstanceEnterpriseModeFeatures().slug).toBe("enterprise");
  });

  test("enables every enterprise capability flag", () => {
    const plan = getInstanceEnterpriseModeFeatures();
    for (const flag of ENTERPRISE_CAPABILITY_FLAGS) {
      expect(plan[flag], `expected ${flag} to be enabled`).toBe(true);
    }
  });

  test("bypasses seat gating with unlimited limits and no identity-limit enforcement", () => {
    const plan = getInstanceEnterpriseModeFeatures();
    expect(plan.workspaceLimit).toBeNull();
    expect(plan.memberLimit).toBeNull();
    expect(plan.identityLimit).toBeNull();
    expect(plan.enforceIdentityLimit).toBeFalsy();
    // enterprise seat-limit bypass check used across identity/membership services
    expect(plan.slug === "enterprise" && !plan.enforceIdentityLimit).toBe(true);
  });

  test("sets usable (non-zero) limits for features the free default zeroes out", () => {
    const plan = getInstanceEnterpriseModeFeatures();
    // 0 would disable audit-log persistence entirely
    expect(plan.auditLogsRetentionDays).toBeGreaterThan(0);
    expect(plan.auditLogStreamLimit).toBeGreaterThan(0);
    expect(plan.honeyTokenLimit).toBeGreaterThan(0);
  });

  test("does not mutate the shared free-tier default (cloud/v2 projection base stays free)", () => {
    // The cloud + self-hosted-v2 entitlement projection uses getDefaultOnPremFeatures() as its base,
    // so the enterprise override must not leak enterprise flags back into the free default.
    const free = getDefaultOnPremFeatures();
    expect(free.slug).toBeNull();
    expect(free.rbac).toBe(false);
    expect(free.samlSSO).toBe(false);
    expect(free.auditLogs).toBe(false);
    expect(free.honeyTokenLimit).toBe(0);
  });
});
