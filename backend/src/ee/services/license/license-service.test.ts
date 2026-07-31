import { beforeEach, describe, expect, test, vi } from "vitest";

import { licenseServiceFactory } from "./license-service";
import { InstanceType, LicenseType, TFeatureSet, TLicenseKeyConfig, TOfflineLicenseContents } from "./license-types";

const mocks = vi.hoisted(() => ({
  cloudRefreshLicense: vi.fn(),
  onPremRefreshLicense: vi.fn(),
  onPremGet: vi.fn(),
  onPremPatch: vi.fn(),
  getDefaultOnPremFeatures: vi.fn(),
  getInstanceEnterpriseModeFeatures: vi.fn(),
  getLicenseKeyConfig: vi.fn(),
  projectV2ToFeatureSet: vi.fn(),
  verifyOfflineLicense: vi.fn()
}));

vi.mock("@app/lib/crypto", () => ({
  verifyOfflineLicense: mocks.verifyOfflineLicense
}));

vi.mock("@app/lib/logger", () => ({
  logger: {
    debug: vi.fn(),
    error: vi.fn(),
    info: vi.fn(),
    warn: vi.fn()
  }
}));

vi.mock("@app/services/license-client/dual-read/entitlement-projection", () => ({
  projectV2ToFeatureSet: mocks.projectV2ToFeatureSet
}));

vi.mock("./license-fns", () => ({
  getDefaultOnPremFeatures: mocks.getDefaultOnPremFeatures,
  getInstanceEnterpriseModeFeatures: mocks.getInstanceEnterpriseModeFeatures,
  getLicenseKeyConfig: mocks.getLicenseKeyConfig,
  setupLicenseRequestWithStore: (_baseUrl: string, refreshUrl: string) => {
    const isCloud = refreshUrl.includes("license-server-login");
    return {
      refreshLicense: isCloud ? mocks.cloudRefreshLicense : mocks.onPremRefreshLicense,
      request: {
        delete: vi.fn(),
        get: isCloud ? vi.fn() : mocks.onPremGet,
        patch: isCloud ? vi.fn() : mocks.onPremPatch,
        post: vi.fn()
      }
    };
  }
}));

const FREE_PLAN = { slug: null, identitiesUsed: 0 } as TFeatureSet;
const ENTERPRISE_PLAN = { slug: "enterprise", identitiesUsed: 0 } as TFeatureSet;
const ONLINE_PLAN = { slug: "pro", identitiesUsed: 0 } as TFeatureSet;
const V2_PLAN = { slug: "advanced", identitiesUsed: 0 } as TFeatureSet;
const OFFLINE_PLAN = { slug: "offline-source", identitiesUsed: 0 } as TFeatureSet;

const makeService = (
  envOverrides: Record<string, string | undefined> = {},
  licenseClient?: {
    getEntitlements: ReturnType<typeof vi.fn>;
    getSubscription: ReturnType<typeof vi.fn>;
    refreshEntitlements: ReturnType<typeof vi.fn>;
  }
) => {
  const projectDAL = {
    countOfBillableOrgProjects: vi.fn().mockResolvedValue(0)
  };
  const licenseDAL = {
    countOfOrgMembers: vi.fn().mockResolvedValue(0),
    countOrgUsersAndIdentities: vi.fn().mockResolvedValue(0)
  };

  return licenseServiceFactory({
    envConfig: {
      LICENSE_SERVER_URL: "https://license.example.test",
      LICENSE_SERVER_KEY: undefined,
      LICENSE_KEY: undefined,
      LICENSE_KEY_OFFLINE: undefined,
      INTERNAL_REGION: undefined,
      SITE_URL: "https://example.test",
      LICENSE_SERVER_V2_MODE: "off",
      LICENSE_SERVER_V2_SERVICE_KEY: undefined,
      DISABLE_LICENSE_V1_CLOUD: false,
      ...envOverrides
    } as never,
    orgDAL: {} as never,
    permissionService: {} as never,
    licenseDAL: licenseDAL as never,
    keyStore: {} as never,
    projectDAL: projectDAL as never,
    licenseClient: licenseClient as never
  });
};

const expectLicensedPlan = (service: ReturnType<typeof licenseServiceFactory>, instanceType: InstanceType) => {
  expect(service.getInstanceType()).toBe(instanceType);
  expect(service.isValidLicense).toBe(true);
  expect(mocks.getInstanceEnterpriseModeFeatures).not.toHaveBeenCalled();
};

describe("licenseServiceFactory init", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getDefaultOnPremFeatures.mockImplementation(() => ({ ...FREE_PLAN }));
    mocks.getInstanceEnterpriseModeFeatures.mockImplementation(() => ({ ...ENTERPRISE_PLAN }));
    mocks.getLicenseKeyConfig.mockReturnValue({ isValid: false } satisfies TLicenseKeyConfig);
    mocks.cloudRefreshLicense.mockResolvedValue("cloud-token");
    mocks.onPremRefreshLicense.mockResolvedValue("on-prem-token");
    mocks.onPremGet.mockResolvedValue({ data: { currentPlan: { ...ONLINE_PLAN } } });
    mocks.onPremPatch.mockResolvedValue(undefined);
    mocks.projectV2ToFeatureSet.mockReturnValue({ ...V2_PLAN });
    mocks.verifyOfflineLicense.mockResolvedValue(true);
  });

  test("enables Enterprise Mode only for the unlicensed self-hosted fallthrough", async () => {
    const service = makeService();

    await service.init();

    expect(service.getInstanceType()).toBe(InstanceType.OnPrem);
    expect(service.isValidLicense).toBe(true);
    expect(service.onPremFeatures).toStrictEqual(ENTERPRISE_PLAN);
    expect(mocks.getInstanceEnterpriseModeFeatures).toHaveBeenCalledOnce();
  });

  test("preserves the License Server v2 cloud early return", async () => {
    const service = makeService({ LICENSE_SERVER_V2_SERVICE_KEY: "service-key" });

    await service.init();

    expectLicensedPlan(service, InstanceType.Cloud);
    expect(service.onPremFeatures).toStrictEqual(FREE_PLAN);
  });

  test("preserves the legacy cloud early return", async () => {
    const service = makeService({ LICENSE_SERVER_KEY: "cloud-key" });

    await service.init();

    expectLicensedPlan(service, InstanceType.Cloud);
    expect(mocks.cloudRefreshLicense).toHaveBeenCalledOnce();
    expect(service.onPremFeatures).toStrictEqual(FREE_PLAN);
  });

  test("preserves the License Server v2 self-hosted early return", async () => {
    mocks.getLicenseKeyConfig.mockReturnValue({
      isValid: true,
      licenseKey: "infisical_lk_test",
      type: LicenseType.OnlineV2
    });
    const licenseClient = {
      getEntitlements: vi.fn().mockResolvedValue({ features: {}, products: [] }),
      getSubscription: vi.fn().mockResolvedValue({ items: [{ plan: "advanced" }] }),
      refreshEntitlements: vi.fn()
    };
    const service = makeService({ LICENSE_KEY: "infisical_lk_test" }, licenseClient);

    await service.init();

    expectLicensedPlan(service, InstanceType.EnterpriseOnPremV2);
    expect(service.onPremFeatures).toMatchObject({ slug: "advanced" });
    expect(licenseClient.getEntitlements).toHaveBeenCalledWith({ id: "self-hosted" });
  });

  test("preserves the legacy online self-hosted early return", async () => {
    mocks.getLicenseKeyConfig.mockReturnValue({
      isValid: true,
      licenseKey: "online-key",
      type: LicenseType.Online
    });
    const service = makeService({ LICENSE_KEY: "online-key" });

    await service.init();

    expectLicensedPlan(service, InstanceType.EnterpriseOnPrem);
    expect(mocks.onPremRefreshLicense).toHaveBeenCalledOnce();
    expect(service.onPremFeatures).toMatchObject({ slug: "pro" });
  });

  test("preserves the verified offline self-hosted early return", async () => {
    const contents: TOfflineLicenseContents = {
      license: {
        issuedTo: "test",
        licenseId: "license-id",
        customerId: "customer-id",
        issuedAt: "2026-07-31T00:00:00.000Z",
        expiresAt: null,
        terminatesAt: null,
        features: OFFLINE_PLAN
      },
      signature: "signature"
    };
    const licenseKey = Buffer.from(JSON.stringify(contents)).toString("base64");
    mocks.getLicenseKeyConfig.mockReturnValue({
      isValid: true,
      licenseKey,
      type: LicenseType.Offline
    });
    const service = makeService({ LICENSE_KEY: licenseKey });

    await service.init();

    expectLicensedPlan(service, InstanceType.EnterpriseOnPremOffline);
    expect(mocks.verifyOfflineLicense).toHaveBeenCalledOnce();
    expect(service.onPremFeatures).toMatchObject({ slug: "enterprise" });
  });

  test("does not grant Enterprise Mode to an invalid offline license", async () => {
    const contents: TOfflineLicenseContents = {
      license: {
        issuedTo: "test",
        licenseId: "license-id",
        customerId: "customer-id",
        issuedAt: "2026-07-31T00:00:00.000Z",
        expiresAt: null,
        terminatesAt: null,
        features: OFFLINE_PLAN
      },
      signature: "invalid-signature"
    };
    const licenseKey = Buffer.from(JSON.stringify(contents)).toString("base64");
    mocks.getLicenseKeyConfig.mockReturnValue({ isValid: true, licenseKey, type: LicenseType.Offline });
    mocks.verifyOfflineLicense.mockResolvedValue(false);
    const service = makeService({ LICENSE_KEY: licenseKey });

    await service.init();

    expect(service.getInstanceType()).toBe(InstanceType.OnPrem);
    expect(service.onPremFeatures).toStrictEqual(FREE_PLAN);
    expect(mocks.getInstanceEnterpriseModeFeatures).not.toHaveBeenCalled();
  });

  test("does not grant Enterprise Mode to an expired offline license", async () => {
    const contents: TOfflineLicenseContents = {
      license: {
        issuedTo: "test",
        licenseId: "license-id",
        customerId: "customer-id",
        issuedAt: "2025-01-01T00:00:00.000Z",
        expiresAt: null,
        terminatesAt: "2025-01-02T00:00:00.000Z",
        features: OFFLINE_PLAN
      },
      signature: "signature"
    };
    const licenseKey = Buffer.from(JSON.stringify(contents)).toString("base64");
    mocks.getLicenseKeyConfig.mockReturnValue({ isValid: true, licenseKey, type: LicenseType.Offline });
    const service = makeService({ LICENSE_KEY: licenseKey });

    await service.init();

    expect(service.getInstanceType()).toBe(InstanceType.OnPrem);
    expect(service.onPremFeatures).toStrictEqual(FREE_PLAN);
    expect(mocks.getInstanceEnterpriseModeFeatures).not.toHaveBeenCalled();
  });
});
