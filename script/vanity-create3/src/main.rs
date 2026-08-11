//! Brute-force `CREATE3_SALT_TAG` so a Grindurus CREATE3 address matches a vanity pattern.
//!
//! Address derivation mirrors `script/Create3Factory.sol`:
//! ```text
//! salt   = keccak256("grindurus/" ‖ tag ‖ "/" ‖ label)
//! proxy  = CREATE2(NickFactory, salt, PROXY_BYTECODE_HASH)
//! addr   = CREATE(proxy, nonce=1)
//! ```
//!
//! Examples:
//! ```bash
//! cd script/vanity-create3
//! cargo run --release -- --check
//! cargo run --release -- --prefix 9999 --suffix 97a1
//! cargo run --release -- --prefix 9999 --suffix '' --label GRAI/proxy
//! ```

use rayon::prelude::*;
use sha3::{Digest, Keccak256};
use std::env;
use std::fs;
use std::process;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

/// Nick's CREATE2 factory (same as `Create3Factory.DEPLOYER`).
const DEPLOYER: [u8; 20] = [
    0x4e, 0x59, 0xb4, 0x48, 0x47, 0xb3, 0x79, 0x57, 0x85, 0x88, 0x92, 0x0c, 0xa7, 0x8f, 0xbf, 0x26,
    0xc0, 0xb4, 0x95, 0x6c,
];

/// `keccak256(PROXY_BYTECODE)` from `Create3Factory`.
const PROXY_BYTECODE_HASH: [u8; 32] = [
    0x21, 0xc3, 0x5d, 0xbe, 0x1b, 0x34, 0x4a, 0x24, 0x88, 0xcf, 0x33, 0x21, 0xd6, 0xce, 0x54, 0x2f,
    0x8e, 0x9f, 0x30, 0x55, 0x44, 0xff, 0x09, 0xe4, 0x99, 0x3a, 0x62, 0x31, 0x9a, 0x49, 0x7c, 0x1f,
];

struct Args {
    prefix: String,
    suffix: String,
    label: String,
    out: String,
    check: bool,
}

fn print_usage() {
    eprintln!(
        "Usage: vanity-create3 [--prefix HEX] [--suffix HEX] [--label LABEL] [--out FILE] [--check]

Defaults: --prefix 9999 --suffix 97a1 --label GRAI/proxy --out found.txt"
    );
}

fn parse_args() -> Args {
    let mut prefix = "9999".to_string();
    let mut suffix = "97a1".to_string();
    let mut label = "GRAI/proxy".to_string();
    let mut out = "found.txt".to_string();
    let mut check = false;

    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--prefix" => {
                prefix = args.next().unwrap_or_else(|| {
                    eprintln!("missing value for --prefix");
                    process::exit(2);
                });
            }
            "--suffix" => {
                suffix = args.next().unwrap_or_else(|| {
                    eprintln!("missing value for --suffix");
                    process::exit(2);
                });
            }
            "--label" => {
                label = args.next().unwrap_or_else(|| {
                    eprintln!("missing value for --label");
                    process::exit(2);
                });
            }
            "--out" => {
                out = args.next().unwrap_or_else(|| {
                    eprintln!("missing value for --out");
                    process::exit(2);
                });
            }
            "--check" => check = true,
            "-h" | "--help" => {
                print_usage();
                process::exit(0);
            }
            other => {
                eprintln!("unknown arg: {other}");
                print_usage();
                process::exit(2);
            }
        }
    }

    Args {
        prefix,
        suffix,
        label,
        out,
        check,
    }
}

fn keccak(data: &[u8]) -> [u8; 32] {
    Keccak256::digest(data).into()
}

fn make_salt(label: &str, tag: &str) -> [u8; 32] {
    let mut buf = Vec::with_capacity(16 + tag.len() + label.len());
    buf.extend_from_slice(b"grindurus/");
    buf.extend_from_slice(tag.as_bytes());
    buf.push(b'/');
    buf.extend_from_slice(label.as_bytes());
    keccak(&buf)
}

fn create3_address(salt: &[u8; 32]) -> [u8; 20] {
    let mut create2_preimage = [0u8; 85];
    create2_preimage[0] = 0xff;
    create2_preimage[1..21].copy_from_slice(&DEPLOYER);
    create2_preimage[21..53].copy_from_slice(salt);
    create2_preimage[53..85].copy_from_slice(&PROXY_BYTECODE_HASH);
    let proxy_hash = keccak(&create2_preimage);

    let mut rlp = [0u8; 23];
    rlp[0] = 0xd6;
    rlp[1] = 0x94;
    rlp[2..22].copy_from_slice(&proxy_hash[12..]);
    rlp[22] = 0x01;
    let created = keccak(&rlp);

    let mut out = [0u8; 20];
    out.copy_from_slice(&created[12..]);
    out
}

fn address_for_tag(label: &str, tag: &str) -> [u8; 20] {
    create3_address(&make_salt(label, tag))
}

fn parse_hex_nibbles(s: &str) -> Vec<u8> {
    let s = s.trim().trim_start_matches("0x").to_ascii_lowercase();
    if s.is_empty() {
        return Vec::new();
    }
    assert!(s.len() % 2 == 0, "hex length must be even: {s}");
    hex::decode(&s).unwrap_or_else(|e| panic!("invalid hex `{s}`: {e}"))
}

fn matches(addr: &[u8; 20], prefix: &[u8], suffix: &[u8]) -> bool {
    addr.starts_with(prefix) && addr.ends_with(suffix)
}

fn main() {
    let args = parse_args();
    let prefix = parse_hex_nibbles(&args.prefix);
    let suffix = parse_hex_nibbles(&args.suffix);
    assert!(
        prefix.len() + suffix.len() <= 20,
        "prefix+suffix longer than address"
    );

    if args.check {
        let addr = address_for_tag("GRAI/proxy", "grindurus");
        let got = format!("0x{}", hex::encode(addr));
        let expect = "0x0d9dac0c5e3e009aaa5bae60cf34b49aed4e429d";
        assert_eq!(got, expect, "CREATE3 mismatch vs Solidity");
        println!("check ok: tag=grindurus label=GRAI/proxy -> {got}");
        return;
    }

    let bits = (prefix.len() + suffix.len()) * 8;
    let expected = if bits >= 63 {
        u64::MAX
    } else {
        1u64 << bits
    };
    eprintln!(
        "grinding label={} prefix=0x{} suffix=0x{} (~2^{bits} tries, E[n]={expected})",
        args.label,
        hex::encode(&prefix),
        hex::encode(&suffix),
    );

    let found = Arc::new(AtomicBool::new(false));
    let checked = Arc::new(AtomicU64::new(0));
    let t0 = Instant::now();

    {
        let found = Arc::clone(&found);
        let checked = Arc::clone(&checked);
        std::thread::spawn(move || loop {
            std::thread::sleep(std::time::Duration::from_secs(5));
            if found.load(Ordering::Relaxed) {
                break;
            }
            let n = checked.load(Ordering::Relaxed);
            let secs = t0.elapsed().as_secs_f64().max(0.001);
            eprintln!("checked={n} rate={:.0}/s", n as f64 / secs);
        });
    }

    let label = args.label.clone();
    let out_path = args.out.clone();

    let hit = (0u64..u64::MAX).into_par_iter().find_any(|&i| {
        if found.load(Ordering::Relaxed) {
            return false;
        }
        checked.fetch_add(1, Ordering::Relaxed);
        let tag = i.to_string();
        let addr = address_for_tag(&label, &tag);
        if matches(&addr, &prefix, &suffix) {
            found.store(true, Ordering::Relaxed);
            let hexaddr = hex::encode(addr);
            println!("FOUND tag={tag} addr=0x{hexaddr}");
            println!("CREATE3_SALT_TAG={tag}");
            let _ = fs::write(&out_path, format!("{tag}\n0x{hexaddr}\n"));
            return true;
        }
        false
    });

    if hit.is_none() {
        eprintln!("exhausted u64 tag space without a hit");
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_solidity_create3() {
        let addr = address_for_tag("GRAI/proxy", "grindurus");
        assert_eq!(
            hex::encode(addr),
            "0d9dac0c5e3e009aaa5bae60cf34b49aed4e429d"
        );
    }
}
