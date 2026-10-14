// Generates cross-implementation fixtures with near-api-js, near-seed-phrase and tweetnacl.
const path = require("path");
const nodeModules = process.argv[2];
const n = require(path.join(nodeModules, "near-api-js"));
const { parseSeedPhrase } = require(path.join(nodeModules, "near-seed-phrase"));
const nacl = require(path.join(nodeModules, "tweetnacl"));
const crypto = require("crypto");

const phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const ledgerPath = "m/44'/397'/0'/0'/1'";
const cliPath = "m/44'/397'/0'";
const kLedger = parseSeedPhrase(phrase, ledgerPath);
const kCli = parseSeedPhrase(phrase, cliPath);
const kp = n.KeyPair.fromString(kLedger.secretKey);
const pk = kp.getPublicKey();
const other = n.KeyPair.fromString(parseSeedPhrase(phrase, "m/44'/397'/1'").secretKey).getPublicKey();
const blockHash = n.baseDecode("4reLvkAWfqk5fsqio1KLudk46cqRz9erQdaHkWZKMJDZ");
const b64 = (u8) => Buffer.from(u8).toString("base64");
const sha = (u8) => crypto.createHash("sha256").update(Buffer.from(u8)).digest();
const A = n.actions;
const mk = (receiver, acts, nonce = 7n) => n.createTransaction("alice.testnet", pk, receiver, nonce, acts, blockHash);

const code = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]);
const cases = {
    transfer: mk("bob.testnet", [A.transfer(1500000000000000000000000n)]),
    createAccount: mk("sub.alice.testnet", [
        A.createAccount(),
        A.transfer(100000000000000000000000n),
        A.addFullAccessKey(other),
    ]),
    functionCall: mk("usdc.testnet", [
        A.functionCall("ft_transfer", { receiver_id: "bob.testnet", amount: "1000000" }, 30000000000000n, 1n),
    ]),
    functionCallBinary: mk("contract.testnet", [
        A.functionCall("raw", new Uint8Array([1, 2, 3, 255]), 300000000000000n, 0n),
    ]),
    deployContract: mk("alice.testnet", [A.deployContract(code)]),
    stake: mk("alice.testnet", [A.stake(42000000000000000000000000n, other)]),
    addFunctionCallKey: mk("alice.testnet", [
        A.addFunctionCallAccessKey(other, "app.testnet", ["a", "b"], 250000000000000000000000n),
    ]),
    addFunctionCallKeyNoAllowance: mk("alice.testnet", [
        A.addFunctionCallAccessKey(other, "app.testnet", [], undefined),
    ]),
    deleteKey: mk("alice.testnet", [A.deleteKey(pk)]),
    deleteAccount: mk("alice.testnet", [A.deleteAccount("bob.testnet")]),
    deployGlobalByHash: mk("alice.testnet", [A.deployGlobalContract(code, "codeHash")]),
    deployGlobalByAccount: mk("alice.testnet", [A.deployGlobalContract(code, "accountId")]),
    useGlobalByAccount: mk("alice.testnet", [A.useGlobalContract({ accountId: "global.testnet" })]),
    useGlobalByHash: mk("alice.testnet", [A.useGlobalContract({ codeHash: new Uint8Array(32).fill(7) })]),
};

const out = {
    phrase,
    ledgerPath,
    cliPath,
    ledgerPublicKey: kLedger.publicKey,
    ledgerSecretKey: kLedger.secretKey,
    cliPublicKey: kCli.publicKey,
    cliSecretKey: kCli.secretKey,
    transactions: {},
};
for (const [name, tx] of Object.entries(cases)) {
    const bytes = n.encodeTransaction(tx);
    const hash = sha(bytes);
    const sig = nacl.sign.detached(hash, kp.secretKey ? n.baseDecode(kLedger.secretKey.split(":")[1]) : null);
    const signed = new n.SignedTransaction({ transaction: tx, signature: new n.Signature({ keyType: 0, data: sig }) });
    out.transactions[name] = {
        borsh: b64(bytes),
        hash: n.baseEncode(hash),
        signature: b64(sig),
        signed: b64(n.encodeSignedTransaction ? n.encodeSignedTransaction(signed) : signed.encode()),
    };
}

// Delegate action (NEP-366) and a transaction relaying it.
const da = n.buildDelegateAction({
    actions: [A.transfer(5n), A.functionCall("ping", {}, 10000000000000n, 0n)],
    maxBlockHeight: 1000n,
    nonce: 9n,
    publicKey: pk,
    receiverId: "app.testnet",
    senderId: "alice.testnet",
});
const daBytes = n.encodeDelegateAction(da);
const daHash = sha(daBytes);
const secret = n.baseDecode(kLedger.secretKey.split(":")[1]);
const daSig = nacl.sign.detached(daHash, secret);
out.delegate = { prefixedBorsh: b64(daBytes), hash: n.baseEncode(daHash), signature: b64(daSig) };
const signedDelegate = A.signedDelegate({
    delegateAction: da,
    signature: new n.Signature({ keyType: 0, data: daSig }),
});
const relay = n.createTransaction("relayer.testnet", other, "alice.testnet", 3n, [signedDelegate], blockHash);
out.relayTransaction = { borsh: b64(n.encodeTransaction(relay)) };

// NEP-413: borsh(payload) built by hand, tag prepended, sha256, ed25519.
function str(s) {
    const b = Buffer.from(s, "utf8");
    const l = Buffer.alloc(4);
    l.writeUInt32LE(b.length);
    return Buffer.concat([l, b]);
}
const nonce = Buffer.alloc(32, 1);
const payload = Buffer.concat([
    str("Login to app"),
    nonce,
    str("app.near"),
    Buffer.from([1]),
    str("https://app.near/cb"),
]);
const tag = Buffer.alloc(4);
tag.writeUInt32LE(2 ** 31 + 413);
const msgHash = sha(Buffer.concat([tag, payload]));
out.nep413 = {
    payload: b64(payload),
    hash: n.baseEncode(msgHash),
    signature: b64(nacl.sign.detached(msgHash, secret)),
};
process.stdout.write(JSON.stringify(out, null, 2));
