import { generateKeyPairSync, randomBytes } from "node:crypto";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// A throwaway APNs-shaped key so the tests can check the JWT signature.
const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });

export default defineConfig({
  plugins: [
    cloudflareTest(async () => ({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          HMAC_KEY: randomBytes(32).toString("base64url"),
          APNS_KEY: privateKey.export({ type: "pkcs8", format: "pem" }),
          APNS_KEY_ID: "TESTKEY123",
          TEST_APNS_PUBLIC_JWK: JSON.stringify(publicKey.export({ format: "jwk" })),
          TEST_MIGRATIONS: await readD1Migrations("./migrations"),
          COALESCE_MS: "3000",
        },
      },
    })),
  ],
  test: {
    setupFiles: ["./test/setup.js"],
  },
});
