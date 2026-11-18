import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import {
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  sign as cryptoSign,
  type KeyObject,
} from 'node:crypto'

export interface SignResult {
  /** zip 的 ed25519 签名 base64；空串 = 密钥缺失跳过签名 */
  signatureB64: string
  /** 公钥 base64（随 repo.json 顶层分发）；空串同上 */
  pubkeyB64: string
}

/** ed25519 私钥 seed（32 字节）的 PKCS#8 DER 前缀 */
const PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex')

/**
 * 纯 TS ed25519 签名（与旧 cargo sign_plugin 输出完全兼容）：
 *   signature = ed25519_sign(seed, zip 全部字节)  → 64 字节 base64
 *   pubkey    = seed 派生公钥（32 字节）           → base64
 * 密钥查找：SWALLOWNOTE_PLUGIN_SIGNING_KEY（base64 seed，CI 同源），
 * 或自 cwd 向上寻找 package/.signing-key。
 * 密钥缺失不视为打包失败，返回空签名（未签名 zip 仍可本地拖拽安装）。
 */
export function signZip(zipPath: string): SignResult {
  const seed = loadSigningSeed()
  if (!seed || seed.length !== 32) {
    process.stderr.write(
      '  ⚠ 未找到签名密钥（SWALLOWNOTE_PLUGIN_SIGNING_KEY / package/.signing-key），已跳过签名\n'
    )
    process.stderr.write('  ⚠ 未签名 zip 无法通过市场安装校验，仍可本地拖拽安装\n')
    return { signatureB64: '', pubkeyB64: '' }
  }
  const priv = createPrivateKey({
    key: Buffer.concat([PKCS8_PREFIX, seed]),
    format: 'der',
    type: 'pkcs8',
  })
  const signature = cryptoSign(null, readFileSync(zipPath), priv)
  const pubkeyRaw = createPublicKey(priv).export({ type: 'spki', format: 'der' }).subarray(-32)
  process.stdout.write(`  ✓ 已签名（ed25519, pubkey ${pubkeyRaw.toString('base64').slice(0, 12)}...）\n`)
  return { signatureB64: signature.toString('base64'), pubkeyB64: pubkeyRaw.toString('base64') }
}

/** 生成新密钥对：返回 { seedB64, pubkeyB64 }（keygen 命令与密钥丢失重建用） */
export function generateKeyPair(): { seedB64: string; pubkeyB64: string } {
  const { privateKey } = generateKeyPairSync('ed25519')
  const der = privateKey.export({ type: 'pkcs8', format: 'der' }) as Buffer
  const seed = der.subarray(-32)
  const pub = createPublicKey(privateKey).export({ type: 'spki', format: 'der' }) as Buffer
  return { seedB64: seed.toString('base64'), pubkeyB64: pub.subarray(-32).toString('base64') }
}

/** 自 cwd 向上查找 package/.signing-key；env 优先。返回原始 seed（可能非 32 字节，由调用方校验） */
function loadSigningSeed(): Buffer | null {
  const envKey = process.env.SWALLOWNOTE_PLUGIN_SIGNING_KEY
  if (envKey && envKey.trim()) {
    return Buffer.from(envKey.trim(), 'base64')
  }
  let dir = process.cwd()
  for (;;) {
    const p = join(dir, 'package', '.signing-key')
    if (existsSync(p)) {
      return Buffer.from(readFileSync(p, 'utf8').trim(), 'base64')
    }
    const parent = dirname(dir)
    if (parent === dir) return null
    dir = parent
  }
}
