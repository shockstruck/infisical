import { TInstanceFeatures } from "../../../ce/models/instance-entitlements";
import { PlanFeature, PlanLimit, PlanProduct } from "../../../ce/models/plan";
import { communityFeatures } from "./entitlement-projection";

export const getInstanceEnterpriseModeFeatures = (): TInstanceFeatures => ({
  ...communityFeatures(),
  ...Object.fromEntries(Object.values(PlanFeature).map((feature) => [feature, true])),
  ...Object.fromEntries(Object.values(PlanLimit).map((limit) => [limit, null])),
  ...Object.fromEntries(Object.values(PlanProduct).map((product) => [product, null])),
  slug: "enterprise",
  enforceIdentityLimit: false,
  auditLogsRetentionDays: 36500,
  auditLogStreamLimit: Number.MAX_SAFE_INTEGER,
  honeyTokenLimit: Number.MAX_SAFE_INTEGER,
  pkiLegacyTemplates: true,
  fips: true,
  instanceUserManagement: true
});
