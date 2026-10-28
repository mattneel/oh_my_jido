// Encrypted secret storage for this origin.
//
// Secrets are encrypted with AES-GCM under a non-extractable WebCrypto key.
// The key and the ciphertexts live in IndexedDB; page scripts can use the key
// but cannot export its bytes. Each secret's name is authenticated data.

const DATABASE = "oh-my-jido";
const STORE = "secrets";
const KEY = "encryption-key";

function open() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE, 1);
    request.onupgradeneeded = () => request.result.createObjectStore(STORE);
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function run(database, mode, operation) {
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(STORE, mode);
    const request = operation(transaction.objectStore(STORE));
    transaction.oncomplete = () => resolve(request.result);
    transaction.onerror = () => reject(transaction.error);
  });
}

async function encryptionKey(database) {
  const existing = await run(database, "readonly", (store) => store.get(KEY));
  if (existing) return existing;

  const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, [
    "encrypt",
    "decrypt",
  ]);
  await run(database, "readwrite", (store) => store.put(key, KEY));
  return key;
}

async function withDatabase(operation) {
  const database = await open();
  try {
    return await operation(database);
  } finally {
    database.close();
  }
}

const label = (name) => new TextEncoder().encode(`oh-my-jido:${name}`);

export function save(name, text) {
  return withDatabase(async (database) => {
    const key = await encryptionKey(database);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const data = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv, additionalData: label(name) },
      key,
      new TextEncoder().encode(text),
    );
    await run(database, "readwrite", (store) => store.put({ iv, data }, `secret:${name}`));
    return true;
  });
}

export function load(name) {
  return withDatabase(async (database) => {
    const record = await run(database, "readonly", (store) => store.get(`secret:${name}`));
    if (!record) return null;

    const key = await encryptionKey(database);
    const data = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: record.iv, additionalData: label(name) },
      key,
      record.data,
    );
    return new TextDecoder().decode(data);
  });
}

export function remove(name) {
  return withDatabase(async (database) => {
    await run(database, "readwrite", (store) => store.delete(`secret:${name}`));
    return true;
  });
}
