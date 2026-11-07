//! The computer's side of NEAR Signer's camera transfer: a request becomes a loop of QR codes
//! for the phone's camera, and the phone's answer, one QR code (or its typed text), becomes a
//! signature or a public key. The wire format is in the near-signer repository's README,
//! "Camera transfer (QR codes)"; the Swift core and `host/optical/` (JavaScript) implement the
//! same bytes.
//!
//! [`terminal::run`] does the whole exchange in a terminal. The pieces are public for tools
//! that draw the codes themselves.

use std::collections::{HashMap, HashSet};
use std::fmt;

/// Every request code starts with it.
pub const FRAME_PREFIX: &str = "NS1:";
/// The most bytes one frame carries.
pub const MAX_FRAGMENT_SIZE: usize = 1200;
/// The Bluetooth payload limit plus the instruction and path in front of it.
pub const MAX_MESSAGE_LENGTH: usize = 1_600_021;
const MAX_FRAGMENT_COUNT: usize = 65_535;
const HEADER_LENGTH: usize = 19;
const FRAME_TYPE: u8 = 0x01;
const RESPONSE_TYPE: u8 = 0x02;
const PATH_LEVELS: usize = 5;
const HARDENED: u32 = 0x8000_0000;
/// Set on the instruction byte when the payload is sent compressed (raw DEFLATE after a u32
/// length).
const COMPRESSED_FLAG: u8 = 0x80;
/// The most a payload may inflate to: the Bluetooth limit.
const MAX_PAYLOAD_LENGTH: usize = 1_600_000;
/// Payloads shorter than this are never worth compressing.
const COMPRESS_FROM: usize = 64;

/// Base45 (RFC 9285): two bytes become three characters of the QR alphanumeric set, the densest
/// text a QR code holds. The request frames use it.
pub mod base45 {
    const ALPHABET: &[u8; 45] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

    fn value(character: u8) -> Option<usize> {
        ALPHABET.iter().position(|&c| c == character)
    }

    pub fn encode(bytes: &[u8]) -> String {
        let mut text = String::with_capacity(bytes.len().div_ceil(2) * 3);
        let mut chunks = bytes.chunks_exact(2);
        for pair in &mut chunks {
            let value = usize::from(pair[0]) << 8 | usize::from(pair[1]);
            text.push(ALPHABET[value % 45] as char);
            text.push(ALPHABET[value / 45 % 45] as char);
            text.push(ALPHABET[value / 45 / 45] as char);
        }
        if let [last] = chunks.remainder() {
            let value = usize::from(*last);
            text.push(ALPHABET[value % 45] as char);
            text.push(ALPHABET[value / 45] as char);
        }
        text
    }

    /// None for characters outside the alphabet, a length of 3n + 1, or a group above 65 535
    /// (255 for the final pair).
    pub fn decode(text: &str) -> Option<Vec<u8>> {
        let characters = text.as_bytes();
        if characters.len() % 3 == 1 {
            return None;
        }
        let mut bytes = Vec::with_capacity(characters.len() / 3 * 2 + 1);
        let mut index = 0;
        while index < characters.len() {
            let c = value(characters[index])?;
            let d = value(characters[index + 1])?;
            if characters.len() - index >= 3 {
                let e = value(characters[index + 2])?;
                let value = c + d * 45 + e * 45 * 45;
                if value > 0xFFFF {
                    return None;
                }
                bytes.push((value >> 8) as u8);
                bytes.push((value & 0xFF) as u8);
                index += 3;
            } else {
                let value = c + d * 45;
                if value > 0xFF {
                    return None;
                }
                bytes.push(value as u8);
                index += 2;
            }
        }
        Some(bytes)
    }
}

/// Crockford's base32: the response is shown in it, because a person may have to type it.
/// Encoding is uppercase without padding; decoding forgives case, spaces, hyphens, and the
/// look-alikes `I`, `L` (1) and `O` (0).
pub mod base32 {
    const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    fn value(character: u8) -> Option<u32> {
        match character.to_ascii_uppercase() {
            b'I' | b'L' => Some(1),
            b'O' => Some(0),
            c => ALPHABET.iter().position(|&a| a == c).map(|v| v as u32),
        }
    }

    pub fn encode(bytes: &[u8]) -> String {
        let mut text = String::with_capacity((bytes.len() * 8).div_ceil(5));
        let mut buffer: u32 = 0;
        let mut bits = 0;
        for &byte in bytes {
            buffer = buffer << 8 | u32::from(byte);
            bits += 8;
            while bits >= 5 {
                bits -= 5;
                text.push(ALPHABET[(buffer >> bits & 0x1F) as usize] as char);
            }
            buffer &= (1 << bits) - 1;
        }
        if bits > 0 {
            text.push(ALPHABET[(buffer << (5 - bits) & 0x1F) as usize] as char);
        }
        text
    }

    /// None for any other character, or when the characters don't end on a byte boundary with
    /// zero padding bits (a typo in the last character).
    pub fn decode(text: &str) -> Option<Vec<u8>> {
        let mut bytes = Vec::with_capacity(text.len() * 5 / 8);
        let mut buffer: u32 = 0;
        let mut bits = 0;
        for &character in text.as_bytes() {
            if character == b' ' || character == b'-' {
                continue;
            }
            buffer = buffer << 5 | value(character)?;
            bits += 5;
            if bits >= 8 {
                bits -= 8;
                bytes.push((buffer >> bits & 0xFF) as u8);
            }
            buffer &= (1 << bits) - 1;
        }
        if bits >= 5 || buffer != 0 {
            return None;
        }
        Some(bytes)
    }
}

/// Base58 (the Bitcoin alphabet NEAR uses for keys and hashes).
pub mod base58 {
    const ALPHABET: &[u8; 58] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

    pub fn encode(bytes: &[u8]) -> String {
        let mut digits: Vec<u8> = Vec::new();
        for &byte in bytes {
            let mut carry = u32::from(byte);
            for digit in digits.iter_mut() {
                carry += u32::from(*digit) << 8;
                *digit = (carry % 58) as u8;
                carry /= 58;
            }
            while carry > 0 {
                digits.push((carry % 58) as u8);
                carry /= 58;
            }
        }
        let zeros = bytes.iter().take_while(|&&b| b == 0).count();
        let mut text = String::with_capacity(zeros + digits.len());
        text.extend(std::iter::repeat_n('1', zeros));
        text.extend(digits.iter().rev().map(|&d| ALPHABET[d as usize] as char));
        text
    }

    pub fn decode(text: &str) -> Option<Vec<u8>> {
        let mut bytes: Vec<u8> = Vec::new();
        for character in text.bytes() {
            let mut carry = ALPHABET.iter().position(|&c| c == character)? as u32;
            for byte in bytes.iter_mut() {
                carry += u32::from(*byte) * 58;
                *byte = (carry & 0xFF) as u8;
                carry >>= 8;
            }
            while carry > 0 {
                bytes.push((carry & 0xFF) as u8);
                carry >>= 8;
            }
        }
        let zeros = text.bytes().take_while(|&c| c == b'1').count();
        let mut out = vec![0; zeros];
        out.extend(bytes.iter().rev());
        Some(out)
    }
}

/// Standard base64 with padding, as near-cli-rs prints transactions.
pub mod base64 {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    pub fn encode(bytes: &[u8]) -> String {
        let mut text = String::with_capacity(bytes.len().div_ceil(3) * 4);
        for chunk in bytes.chunks(3) {
            let value = chunk
                .iter()
                .enumerate()
                .fold(0u32, |acc, (i, &b)| acc | u32::from(b) << (16 - 8 * i));
            for i in 0..4 {
                if i <= chunk.len() {
                    text.push(ALPHABET[(value >> (18 - 6 * i) & 0x3F) as usize] as char);
                } else {
                    text.push('=');
                }
            }
        }
        text
    }

    pub fn decode(text: &str) -> Option<Vec<u8>> {
        let clean: Vec<u8> = text
            .bytes()
            .filter(|c| !c.is_ascii_whitespace() && *c != b'=')
            .collect();
        if clean.len() % 4 == 1 {
            return None;
        }
        let mut bytes = Vec::with_capacity(clean.len() * 3 / 4);
        for chunk in clean.chunks(4) {
            let mut value = 0u32;
            for (i, &c) in chunk.iter().enumerate() {
                let digit = match c {
                    b'A'..=b'Z' => c - b'A',
                    b'a'..=b'z' => c - b'a' + 26,
                    b'0'..=b'9' => c - b'0' + 52,
                    b'+' | b'-' => 62,
                    b'/' | b'_' => 63,
                    _ => return None,
                };
                value |= u32::from(digit) << (18 - 6 * i);
            }
            for i in 0..chunk.len() - 1 {
                bytes.push((value >> (16 - 8 * i) & 0xFF) as u8);
            }
        }
        Some(bytes)
    }
}

/// CRC-32 (IEEE 802.3, the one zlib and PNG use).
pub fn crc32(bytes: &[u8]) -> u32 {
    crc32fast::hash(bytes)
}

/// Which fragments frame `sequence` of a transfer with `fragment_count` fragments carries: the
/// fragment itself below the count, a pseudo-random XOR set above it, chosen the same way by the
/// computer that shows the frames and the phone that reads them (xorshift32, the ideal soliton
/// degree, a partial Fisher-Yates shuffle).
pub fn fountain_indexes(session_id: u32, sequence: u32, fragment_count: usize) -> Vec<usize> {
    assert!(fragment_count > 0, "a transfer has at least one fragment");
    // Even blocks of K frames carry the fragments in order, so every fragment passes by within 2K
    // frames whenever the phone starts watching; odd blocks mix them to fill in what was missed.
    let count = fragment_count as u32;
    if (sequence / count) % 2 == 0 {
        return vec![(sequence % count) as usize];
    }
    let mut state = session_id ^ sequence.wrapping_mul(0x9E37_79B9);
    if state == 0 {
        state = 0x9E37_79B9;
    }
    let mut next = move || {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        state
    };
    let u = u64::from(next());
    let degree = ((u64::from(u32::MAX) / ((1u64 << 32) - u)) as usize + 1).min(fragment_count);
    // Only the swapped positions of 0..fragment_count are kept, so a large transfer doesn't
    // allocate the whole array per frame.
    let mut swapped: HashMap<usize, usize> = HashMap::new();
    let mut chosen = Vec::with_capacity(degree);
    for i in 0..degree {
        let j = i + (next() % (fragment_count - i) as u32) as usize;
        let at_j = swapped.get(&j).copied().unwrap_or(j);
        let at_i = swapped.get(&i).copied().unwrap_or(i);
        swapped.insert(j, at_i);
        swapped.insert(i, at_j);
        chosen.push(at_j);
    }
    chosen
}

#[derive(Debug)]
pub enum Error {
    /// The message is empty or longer than [`MAX_MESSAGE_LENGTH`].
    MessageTooLong(usize),
    /// The fragment size is not 1..=[`MAX_FRAGMENT_SIZE`].
    FragmentSize(usize),
    /// The message would take more than 65 535 fragments at this fragment size.
    TooManyFragments(usize),
    /// Not five hardened levels under `44'/397'`.
    BadPath(String),
    /// The text is not a response code (a typo, or another QR code).
    NotAResponse,
    /// A response to a different request.
    OtherSession {
        expected: u32,
        got: u32,
    },
    /// The phone answered with this status word instead of `9000`.
    Status(u16),
    Io(std::io::Error),
    /// Standard input ended before an answer was typed.
    Cancelled,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::MessageTooLong(len) => {
                write!(
                    f,
                    "the message is {len} bytes; it must be 1 to {MAX_MESSAGE_LENGTH} bytes"
                )
            }
            Error::FragmentSize(size) => write!(
                f,
                "the fragment size is {size}; it must be 1 to {MAX_FRAGMENT_SIZE}"
            ),
            Error::TooManyFragments(count) => {
                write!(f, "the message would take {count} fragments; at most {MAX_FRAGMENT_COUNT} are possible")
            }
            Error::BadPath(path) => write!(
                f,
                "{path:?} is not a NEAR account path (five hardened levels under 44'/397')"
            ),
            Error::NotAResponse => write!(f, "not a NEAR Signer response code (check for typos)"),
            Error::OtherSession { expected, got } => {
                write!(f, "the response is for another request (session {got:08x}, this one is {expected:08x})")
            }
            Error::Status(status) => write!(f, "{} (status {status:04X})", status_message(*status)),
            Error::Io(error) => write!(f, "{error}"),
            Error::Cancelled => write!(f, "cancelled"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Error::Io(error)
    }
}

fn status_message(status: u16) -> &'static str {
    match status {
        0x9000 => "OK",
        0x6985 => "rejected on the phone",
        0xB005 => "the phone could not decode the request",
        0xB00B => "bad derivation path",
        0xB00D => "the transaction's key is not the phone's key at that path",
        0x5515 => "no key on the phone",
        0x6A80 => "invalid data",
        0x6D00 => "the phone doesn't know this request",
        0x6601 => "the phone is busy with another request",
        _ => "unknown status word",
    }
}

fn push_u32(bytes: &mut Vec<u8>, value: u32) {
    bytes.extend_from_slice(&value.to_be_bytes());
}

/// Raw DEFLATE (RFC 1951, no zlib or gzip header) at the highest level.
fn deflate(bytes: &[u8]) -> Vec<u8> {
    use std::io::Write;
    let mut encoder = flate2::write::DeflateEncoder::new(
        Vec::with_capacity(bytes.len() / 2),
        flate2::Compression::best(),
    );
    // Writing to a Vec cannot fail.
    let _ = encoder.write_all(bytes);
    encoder.finish().unwrap_or_default()
}

/// Inflates raw DEFLATE into exactly `length` bytes: fewer, more, or a stream that doesn't end
/// there is None. The output is bounded before anything is decoded.
fn inflate_exact(deflated: &[u8], length: usize) -> Option<Vec<u8>> {
    use std::io::Read;
    let mut decoder = flate2::read::DeflateDecoder::new(deflated);
    let mut out = Vec::with_capacity(length);
    decoder
        .by_ref()
        .take(length as u64)
        .read_to_end(&mut out)
        .ok()?;
    if out.len() != length {
        return None;
    }
    let mut extra = [0u8; 1];
    match decoder.read(&mut extra) {
        Ok(0) => Some(out),
        _ => None,
    }
}

fn read_u32(bytes: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes([
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
    ])
}

fn xor_into(target: &mut [u8], other: &[u8]) {
    debug_assert_eq!(target.len(), other.len());
    for (t, o) in target.iter_mut().zip(other) {
        *t ^= o;
    }
}

/// One QR code of a request, decoded.
struct Frame {
    session_id: u32,
    length: usize,
    fragment_size: usize,
    crc: u32,
    sequence: u32,
    data: Vec<u8>,
}

impl Frame {
    /// None unless `text` is a well-formed frame within the limits; other QR codes give None.
    fn parse(text: &str) -> Option<Self> {
        let encoded = text.strip_prefix(FRAME_PREFIX)?;
        let bytes = base45::decode(encoded)?;
        if bytes.len() < HEADER_LENGTH || bytes[0] != FRAME_TYPE {
            return None;
        }
        let frame = Frame {
            session_id: read_u32(&bytes, 1),
            length: read_u32(&bytes, 5) as usize,
            fragment_size: usize::from(bytes[9]) << 8 | usize::from(bytes[10]),
            crc: read_u32(&bytes, 11),
            sequence: read_u32(&bytes, 15),
            data: bytes[HEADER_LENGTH..].to_vec(),
        };
        let within_limits = (1..=MAX_MESSAGE_LENGTH).contains(&frame.length)
            && (1..=MAX_FRAGMENT_SIZE).contains(&frame.fragment_size)
            && frame.data.len() == frame.fragment_size
            && frame.fragment_count() <= MAX_FRAGMENT_COUNT;
        within_limits.then_some(frame)
    }

    fn fragment_count(&self) -> usize {
        self.length.div_ceil(self.fragment_size)
    }

    fn text(&self) -> String {
        let mut bytes = Vec::with_capacity(HEADER_LENGTH + self.data.len());
        bytes.push(FRAME_TYPE);
        push_u32(&mut bytes, self.session_id);
        push_u32(&mut bytes, self.length as u32);
        bytes.push((self.fragment_size >> 8) as u8);
        bytes.push((self.fragment_size & 0xFF) as u8);
        push_u32(&mut bytes, self.crc);
        push_u32(&mut bytes, self.sequence);
        bytes.extend_from_slice(&self.data);
        format!("{FRAME_PREFIX}{}", base45::encode(&bytes))
    }
}

/// The computer's side: splits a message into fragments and produces frame after frame, for as
/// long as the phone needs.
pub struct Sender {
    session_id: u32,
    fragment_size: usize,
    length: usize,
    crc: u32,
    fragments: Vec<Vec<u8>>,
}

impl Sender {
    /// A message shorter than `fragment_size` is sent as one fragment of its own length.
    pub fn new(message: Vec<u8>, session_id: u32, fragment_size: usize) -> Result<Self, Error> {
        if message.is_empty() || message.len() > MAX_MESSAGE_LENGTH {
            return Err(Error::MessageTooLong(message.len()));
        }
        if !(1..=MAX_FRAGMENT_SIZE).contains(&fragment_size) {
            return Err(Error::FragmentSize(fragment_size));
        }
        let fragment_size = fragment_size.min(message.len());
        let count = message.len().div_ceil(fragment_size);
        if count > MAX_FRAGMENT_COUNT {
            return Err(Error::TooManyFragments(count));
        }
        let length = message.len();
        let crc = crc32(&message);
        let mut padded = message;
        padded.resize(count * fragment_size, 0);
        Ok(Sender {
            session_id,
            fragment_size,
            length,
            crc,
            fragments: padded.chunks(fragment_size).map(<[u8]>::to_vec).collect(),
        })
    }

    pub fn session_id(&self) -> u32 {
        self.session_id
    }

    /// K: how many fragments the message takes.
    pub fn fragment_count(&self) -> usize {
        self.fragments.len()
    }

    pub fn fragment_size(&self) -> usize {
        self.fragment_size
    }

    pub fn message_len(&self) -> usize {
        self.length
    }

    /// The text of frame `sequence`, to show as a QR code.
    pub fn frame(&self, sequence: u32) -> String {
        let indexes = fountain_indexes(self.session_id, sequence, self.fragments.len());
        let mut data = self.fragments[indexes[0]].clone();
        for &index in &indexes[1..] {
            xor_into(&mut data, &self.fragments[index]);
        }
        Frame {
            session_id: self.session_id,
            length: self.length,
            fragment_size: self.fragment_size,
            crc: self.crc,
            sequence,
            data,
        }
        .text()
    }
}

/// How far a transfer has come.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Progress {
    /// Fragments recovered.
    pub known: usize,
    /// K, the fragments the message takes.
    pub total: usize,
    /// Message bytes.
    pub length: usize,
    pub session_id: u32,
}

/// What one received code did.
#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Not an `NS1:` frame: another QR code in view. Ignore silently.
    NotAFrame,
    /// The frame carried nothing new.
    Duplicate,
    /// A frame of another transfer, ignored. Three in a row from one new session start over with
    /// it (reported as `Progress`).
    OtherSession,
    Progress(Progress),
    /// The message, checksum verified, padding removed.
    Complete(Vec<u8>),
    /// Checksum mismatch, or frames of one session disagreeing about the message: the receiver
    /// starts over. The text is for the user.
    Invalid(String),
}

struct Session {
    id: u32,
    length: usize,
    fragment_size: usize,
    crc: u32,
    count: usize,
}

struct Mixed {
    unknown: HashSet<usize>,
    data: Vec<u8>,
}

/// Unknown fragment indexes the kept mixed frames may hold in all, per fragment of the message.
/// Each costs a set entry, so without a budget a hostile screen could declare 65 535 one-byte
/// fragments and show frames mixing tens of thousands of them: gigabytes across the kept frames.
/// An honest transfer stays far below it (frames mix about ln K fragments on average).
const HELD_INDEXES_PER_FRAGMENT: usize = 16;

/// The receiving side (the phone's, or a test's): fed the text of every QR code seen, it recovers
/// the message by peeling. Mirrors the Swift receiver rule for rule.
#[derive(Default)]
pub struct Receiver {
    session: Option<Session>,
    known: Vec<Option<Vec<u8>>>,
    known_count: usize,
    mixed: Vec<Mixed>,
    /// Unknown fragment indexes held across `mixed`.
    held_indexes: usize,
    finished: bool,
    progress: Option<Progress>,
    other_session_id: Option<u32>,
    other_session_frames: usize,
}

impl Receiver {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn receive(&mut self, text: &str) -> Outcome {
        let Some(frame) = Frame::parse(text) else {
            return Outcome::NotAFrame;
        };
        match &self.session {
            Some(session) if frame.session_id != session.id => {
                if self.other_session_id == Some(frame.session_id) {
                    self.other_session_frames += 1;
                } else {
                    self.other_session_id = Some(frame.session_id);
                    self.other_session_frames = 1;
                }
                if self.other_session_frames < 3 {
                    return Outcome::OtherSession;
                }
                self.reset();
                self.start(&frame);
            }
            Some(session) => {
                self.other_session_id = None;
                self.other_session_frames = 0;
                if frame.length != session.length
                    || frame.fragment_size != session.fragment_size
                    || frame.crc != session.crc
                {
                    self.reset();
                    return Outcome::Invalid(
                        "The codes disagree about the request (its size or checksum). Scanning starts over.".into(),
                    );
                }
                if self.finished {
                    return Outcome::Duplicate;
                }
            }
            None => self.start(&frame),
        }
        self.absorb(frame)
    }

    pub fn progress(&self) -> Option<&Progress> {
        self.progress.as_ref()
    }

    /// The session in progress or just completed; stays until `reset`.
    pub fn session_id(&self) -> Option<u32> {
        self.session.as_ref().map(|session| session.id)
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    fn start(&mut self, frame: &Frame) {
        let count = frame.fragment_count();
        self.session = Some(Session {
            id: frame.session_id,
            length: frame.length,
            fragment_size: frame.fragment_size,
            crc: frame.crc,
            count,
        });
        self.known = vec![None; count];
        self.known_count = 0;
        self.mixed.clear();
        self.held_indexes = 0;
        self.finished = false;
        self.update_progress();
    }

    fn absorb(&mut self, frame: Frame) -> Outcome {
        let (id, count) = match &self.session {
            Some(session) => (session.id, session.count),
            None => return Outcome::NotAFrame,
        };
        let mut data = frame.data;
        let mut unknown = HashSet::new();
        for index in fountain_indexes(id, frame.sequence, count) {
            match &self.known[index] {
                Some(fragment) => xor_into(&mut data, fragment),
                None => {
                    unknown.insert(index);
                }
            }
        }
        match unknown.len() {
            0 => return Outcome::Duplicate,
            1 => {
                let index = *unknown.iter().next().expect("one unknown");
                self.learn(index, data);
            }
            _ => {
                if self.mixed.iter().any(|entry| entry.unknown == unknown) {
                    return Outcome::Duplicate;
                }
                // Bounded: a hostile or very long stream can't grow memory without end. The
                // oldest frames go first, to keep at most 4096 frames and the budget of unknown
                // indexes.
                let cap = (4 * count).clamp(16, 4096);
                let budget = HELD_INDEXES_PER_FRAGMENT * count;
                while !self.mixed.is_empty()
                    && (self.mixed.len() >= cap || self.held_indexes + unknown.len() > budget)
                {
                    self.held_indexes -= self.mixed.remove(0).unknown.len();
                }
                self.held_indexes += unknown.len();
                self.mixed.push(Mixed { unknown, data });
            }
        }
        self.update_progress();
        if self.known_count < count {
            return Outcome::Progress(self.progress.clone().expect("progress after a frame"));
        }
        let (fragment_size, length, crc) = self
            .session
            .as_ref()
            .map(|s| (s.fragment_size, s.length, s.crc))
            .expect("session");
        self.finished = true;
        self.mixed.clear();
        self.held_indexes = 0;
        let mut message: Vec<u8> = Vec::with_capacity(count * fragment_size);
        for fragment in &self.known {
            message.extend_from_slice(fragment.as_ref().expect("every fragment is known"));
        }
        message.truncate(length);
        if crc32(&message) != crc {
            self.reset();
            return Outcome::Invalid(
                "The request's checksum doesn't match. Scanning starts over.".into(),
            );
        }
        Outcome::Complete(message)
    }

    /// Records a recovered fragment and peels every mixed frame it completes, in cascade.
    fn learn(&mut self, index: usize, data: Vec<u8>) {
        let mut queue = vec![index];
        self.known[index] = Some(data);
        self.known_count += 1;
        while let Some(solved) = queue.pop() {
            let solved_data = self.known[solved]
                .clone()
                .expect("solved fragment is known");
            let mut remaining = Vec::with_capacity(self.mixed.len());
            for mut entry in self.mixed.drain(..) {
                if !entry.unknown.remove(&solved) {
                    remaining.push(entry);
                    continue;
                }
                self.held_indexes -= 1;
                xor_into(&mut entry.data, &solved_data);
                if entry.unknown.len() == 1 {
                    self.held_indexes -= 1;
                    let next = *entry.unknown.iter().next().expect("one unknown");
                    if self.known[next].is_none() {
                        self.known[next] = Some(entry.data);
                        self.known_count += 1;
                        queue.push(next);
                    }
                } else if entry.unknown.len() > 1 {
                    remaining.push(entry);
                }
            }
            self.mixed = remaining;
        }
    }

    /// Unknown fragment indexes held across the kept mixed frames (for tests of the bound).
    #[cfg(test)]
    fn held_indexes(&self) -> usize {
        debug_assert_eq!(
            self.held_indexes,
            self.mixed
                .iter()
                .map(|entry| entry.unknown.len())
                .sum::<usize>()
        );
        self.held_indexes
    }

    fn update_progress(&mut self) {
        if let Some(session) = &self.session {
            self.progress = Some(Progress {
                known: self.known_count,
                total: session.count,
                length: session.length,
                session_id: session.id,
            });
        }
    }
}

/// What the phone is asked to do: the instruction byte of the Ledger APDU it corresponds to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Transaction = 0x02,
    PublicKey = 0x04,
    Nep413 = 0x07,
    Nep366 = 0x08,
}

impl Kind {
    fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0x02 => Some(Kind::Transaction),
            0x04 => Some(Kind::PublicKey),
            0x07 => Some(Kind::Nep413),
            0x08 => Some(Kind::Nep366),
            _ => None,
        }
    }

    /// The name the JavaScript tools use.
    pub fn name(self) -> &'static str {
        match self {
            Kind::Transaction => "transaction",
            Kind::PublicKey => "publicKey",
            Kind::Nep413 => "nep413",
            Kind::Nep366 => "nep366",
        }
    }
}

/// The message the request frames carry: what the Ledger APDU would, with the instruction in
/// front.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub kind: Kind,
    /// The five hardened levels as sent (index | 0x8000_0000).
    pub path: [u32; PATH_LEVELS],
    /// `borsh(Transaction)`, `borsh(Payload)` or `borsh(DelegateAction)`; empty for a public key.
    pub payload: Vec<u8>,
}

impl Request {
    /// `path` is `44'/397'/0'/0'/1'` or `m/44'/397'/0'/0'/1'`: exactly five hardened levels under
    /// `44'/397'`.
    pub fn new(kind: Kind, path: &str, payload: Vec<u8>) -> Result<Self, Error> {
        let path = parse_path(path).ok_or_else(|| Error::BadPath(path.to_string()))?;
        Ok(Request {
            kind,
            path,
            payload,
        })
    }

    /// The plain message: instruction, path, payload.
    pub fn message(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(1 + 4 * PATH_LEVELS + self.payload.len());
        bytes.push(self.kind as u8);
        for &level in &self.path {
            push_u32(&mut bytes, level);
        }
        bytes.extend_from_slice(&self.payload);
        bytes
    }

    /// The message to send: the payload compressed (instruction | 0x80, its length as u32, then
    /// raw DEFLATE) when it is at least 64 bytes and that saves space (contract code shrinks
    /// about three times; a transfer doesn't), else the plain message. A public key request is
    /// never compressed. The signature still covers the plain payload.
    pub fn message_for_transfer(&self) -> Vec<u8> {
        if self.kind == Kind::PublicKey
            || self.payload.len() < COMPRESS_FROM
            || self.payload.len() > MAX_PAYLOAD_LENGTH
        {
            return self.message();
        }
        let deflated = deflate(&self.payload);
        if 4 + deflated.len() >= self.payload.len() {
            return self.message();
        }
        let mut bytes = Vec::with_capacity(1 + 4 * PATH_LEVELS + 4 + deflated.len());
        bytes.push(self.kind as u8 | COMPRESSED_FLAG);
        for &level in &self.path {
            push_u32(&mut bytes, level);
        }
        push_u32(&mut bytes, self.payload.len() as u32);
        bytes.extend_from_slice(&deflated);
        bytes
    }

    /// None if the message is too short, names an unknown instruction or a path that isn't a
    /// NEAR account path, asks for a public key with a payload, or carries a compressed payload
    /// that doesn't inflate to exactly the length it claims.
    pub fn parse(message: &[u8]) -> Option<Self> {
        if message.len() < 1 + 4 * PATH_LEVELS {
            return None;
        }
        let compressed = message[0] & COMPRESSED_FLAG != 0;
        let kind = Kind::from_byte(message[0] & !COMPRESSED_FLAG)?;
        let mut path = [0u32; PATH_LEVELS];
        for (i, level) in path.iter_mut().enumerate() {
            *level = read_u32(message, 1 + 4 * i);
        }
        if !is_account_path(&path) {
            return None;
        }
        let rest = &message[1 + 4 * PATH_LEVELS..];
        let payload = if compressed {
            if kind == Kind::PublicKey || rest.len() < 4 {
                return None;
            }
            let length = read_u32(rest, 0) as usize;
            if length == 0 || length > MAX_PAYLOAD_LENGTH {
                return None;
            }
            inflate_exact(&rest[4..], length)?
        } else {
            rest.to_vec()
        };
        if kind == Kind::PublicKey && !payload.is_empty() {
            return None;
        }
        Some(Request {
            kind,
            path,
            payload,
        })
    }

    /// `m/44'/397'/0'/0'/1'`.
    pub fn path_string(&self) -> String {
        let levels: Vec<String> = self
            .path
            .iter()
            .map(|level| format!("{}'", level & !HARDENED))
            .collect();
        format!("m/{}", levels.join("/"))
    }

    /// What the signature covers: `sha256(borsh)` for a transaction; `sha256(prefix ‖ borsh)`
    /// for a NEP-413 message (`9d 01 00 80`) and a NEP-366 delegate action (`6e 01 00 40`);
    /// None for a public key request.
    pub fn digest(&self) -> Option<[u8; 32]> {
        use sha2::Digest;
        let mut hasher = sha2::Sha256::new();
        match self.kind {
            Kind::PublicKey => return None,
            Kind::Transaction => {}
            Kind::Nep413 => hasher.update([0x9d, 0x01, 0x00, 0x80]),
            Kind::Nep366 => hasher.update([0x6e, 0x01, 0x00, 0x40]),
        }
        hasher.update(&self.payload);
        Some(hasher.finalize().into())
    }
}

fn parse_path(text: &str) -> Option<[u32; PATH_LEVELS]> {
    let text = text.trim();
    let text = text.strip_prefix("m/").unwrap_or(text);
    let mut path = [0u32; PATH_LEVELS];
    let mut levels = text.split('/');
    for level in path.iter_mut() {
        let part = levels.next()?;
        let number = part.strip_suffix('\'').or_else(|| part.strip_suffix('h'))?;
        *level = number.parse::<u32>().ok().filter(|n| *n < HARDENED)? | HARDENED;
    }
    if levels.next().is_some() || !is_account_path(&path) {
        return None;
    }
    Some(path)
}

fn is_account_path(path: &[u32; PATH_LEVELS]) -> bool {
    path.iter().all(|level| level & HARDENED != 0)
        && path[0] == 44 | HARDENED
        && path[1] == 397 | HARDENED
}

/// The phone's answer, one QR code (and typed text) in Crockford base32.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Response {
    pub session_id: u32,
    /// `0x9000` for success; the Bluetooth status words otherwise.
    pub status: u16,
    /// A 64-byte signature or a 32-byte public key; empty on an error.
    pub result: Vec<u8>,
}

impl Response {
    /// Reads typed or scanned text: forgiving about case, spaces and look-alike letters, strict
    /// about the checksum.
    pub fn parse(text: &str) -> Option<Self> {
        let bytes = base32::decode(text.trim())?;
        if bytes.len() < 11 || bytes[0] != RESPONSE_TYPE {
            return None;
        }
        let body = bytes.len() - 4;
        if crc32(&bytes[..body]) != read_u32(&bytes, body) {
            return None;
        }
        Some(Response {
            session_id: read_u32(&bytes, 1),
            status: u16::from(bytes[5]) << 8 | u16::from(bytes[6]),
            result: bytes[7..body].to_vec(),
        })
    }

    pub fn text(&self) -> String {
        let mut bytes = Vec::with_capacity(11 + self.result.len());
        bytes.push(RESPONSE_TYPE);
        push_u32(&mut bytes, self.session_id);
        bytes.extend_from_slice(&self.status.to_be_bytes());
        bytes.extend_from_slice(&self.result);
        let crc = crc32(&bytes);
        push_u32(&mut bytes, crc);
        base32::encode(&bytes)
    }

    /// The text in groups of five, for reading out or typing.
    pub fn grouped(&self) -> String {
        let text = self.text();
        text.as_bytes()
            .chunks(5)
            .map(|group| String::from_utf8_lossy(group).into_owned())
            .collect::<Vec<_>>()
            .join(" ")
    }

    pub fn status_message(&self) -> &'static str {
        status_message(self.status)
    }

    /// The signature, when the status is `9000` and the result is one.
    pub fn signature(&self) -> Option<[u8; 64]> {
        (self.status == 0x9000)
            .then(|| self.result.as_slice().try_into().ok())
            .flatten()
    }

    /// The public key, when the status is `9000` and the result is one.
    pub fn public_key(&self) -> Option<[u8; 32]> {
        (self.status == 0x9000)
            .then(|| self.result.as_slice().try_into().ok())
            .flatten()
    }
}

/// Whether `signature` is `public_key`'s Ed25519 signature of `digest`.
pub fn verify(public_key: &[u8; 32], digest: &[u8; 32], signature: &[u8; 64]) -> bool {
    use ed25519_dalek::Verifier;
    ed25519_dalek::VerifyingKey::from_bytes(public_key)
        .map(|key| {
            key.verify(digest, &ed25519_dalek::Signature::from_bytes(signature))
                .is_ok()
        })
        .unwrap_or(false)
}

/// Showing the codes in a terminal and reading the answer.
pub mod terminal {
    use super::{Error, Request, Response};
    use std::io::{BufRead, IsTerminal, Write};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    const QUIET_ZONE: i64 = 2;

    /// The code for `text` as lines of half-block characters, two module rows per line, with a
    /// quiet zone. Terminals are usually light text on a dark background, so by default the
    /// light modules are the drawn blocks, which gives a normal dark-on-light code; `invert` is
    /// for dark text on a light background.
    pub fn render(text: &str, invert: bool) -> Vec<String> {
        let Some(code) = alphanumeric_code(text).or_else(|| {
            qrcode::QrCode::with_error_correction_level(text.as_bytes(), qrcode::EcLevel::L).ok()
        }) else {
            return vec!["(the text is too long for one QR code)".to_string()];
        };
        let size = code.width() as i64;
        let dark = |x: i64, y: i64| {
            x >= 0
                && y >= 0
                && x < size
                && y < size
                && code[(x as usize, y as usize)] == qrcode::Color::Dark
        };
        let light = |x: i64, y: i64| dark(x, y) == invert;
        let mut lines = Vec::new();
        let mut y = -QUIET_ZONE;
        while y < size + QUIET_ZONE {
            let mut line = String::with_capacity((size + 2 * QUIET_ZONE) as usize * 3);
            for x in -QUIET_ZONE..size + QUIET_ZONE {
                line.push(match (light(x, y), light(x, y + 1)) {
                    (true, true) => '█',
                    (true, false) => '▀',
                    (false, true) => '▄',
                    (false, false) => ' ',
                });
            }
            lines.push(line);
            y += 2;
        }
        lines
    }

    /// The largest of 220, 160, 120, 80 and 50 bytes whose code fits a terminal of `rows` lines
    /// with four to spare, so the whole code is on screen.
    pub fn fitting_fragment_size(rows: usize) -> usize {
        // The biggest code that leaves 7 lines under it: status, caption, instructions, hint,
        // a blank line, the prompt and its help line. Terminal height is what limits the speed.
        for size in [
            1200usize, 1000, 800, 650, 500, 400, 300, 220, 160, 120, 80, 50,
        ] {
            if code_lines(size) + 7 <= rows {
                return size;
            }
        }
        50
    }

    /// The smallest code holding `text` as one alphanumeric segment (5.5 bits a character; frame
    /// and response texts fit that alphabet). One fixed segment, rather than the crate's
    /// segment optimizer, keeps every frame of a transfer at the same version: the block on
    /// screen never changes height between frames, which would leave lines of an earlier frame
    /// under it. `None` for text outside the alphabet or too long for any version.
    fn alphanumeric_code(text: &str) -> Option<qrcode::QrCode> {
        let alphanumeric = text.bytes().all(|b| {
            matches!(b, b'0'..=b'9' | b'A'..=b'Z' | b' ' | b'$' | b'%' | b'*' | b'+' | b'-' | b'.' | b'/' | b':')
        });
        if !alphanumeric {
            return None;
        }
        (1..=40).find_map(|number| {
            let mut bits = qrcode::bits::Bits::new(qrcode::Version::Normal(number));
            bits.push_alphanumeric_data(text.as_bytes()).ok()?;
            bits.push_terminator(qrcode::EcLevel::L).ok()?;
            qrcode::QrCode::with_bits(bits, qrcode::EcLevel::L).ok()
        })
    }

    /// Lines a code of a frame with `fragment_size` bytes takes on screen.
    fn code_lines(fragment_size: usize) -> usize {
        render(&sample_frame(fragment_size), false).len()
    }

    /// Letters, not digits: a run of digits would be packed in numeric mode and size the code
    /// smaller than a real frame's base45 text.
    fn sample_frame(fragment_size: usize) -> String {
        format!(
            "{}{}",
            super::FRAME_PREFIX,
            "A".repeat(((19 + fragment_size) * 3).div_ceil(2))
        )
    }

    /// How many codes fit side by side in `columns`, up to three: the phone reads them all from
    /// one camera frame, so a wide terminal sends that many times faster.
    pub fn codes_side_by_side(columns: usize, code_width: usize) -> usize {
        ((columns + 2) / (code_width + 2)).clamp(1, 3)
    }

    /// Several codes side by side, two spaces apart.
    fn render_row(texts: &[String], invert: bool) -> Vec<String> {
        let codes: Vec<Vec<String>> = texts.iter().map(|text| render(text, invert)).collect();
        let height = codes.iter().map(Vec::len).max().unwrap_or(0);
        (0..height)
            .map(|row| {
                codes
                    .iter()
                    .map(|code| code.get(row).cloned().unwrap_or_default())
                    .collect::<Vec<_>>()
                    .join("  ")
            })
            .collect()
    }

    /// How the codes are shown.
    pub struct Options {
        /// Bytes per frame; None picks the largest that fits the terminal.
        pub fragment_size: Option<usize>,
        /// Frames per second (1–30); `NEAR_SIGNER_QR_FPS` in the environment overrides it.
        pub fps: u32,
        /// Dark text on a light terminal.
        pub invert: bool,
        /// None draws a random one.
        pub session_id: Option<u32>,
        /// A line under the codes saying what is being asked ("Signing the transaction…").
        pub caption: Option<String>,
        /// Codes shown side by side per frame (each a frame of its own); None fits the width.
        pub codes_per_frame: Option<usize>,
        /// Send the payload compressed when that saves space (see `Request::message_for_transfer`).
        pub compress: bool,
    }

    impl Default for Options {
        fn default() -> Self {
            Options {
                fragment_size: None,
                fps: 20,
                invert: false,
                session_id: None,
                caption: None,
                codes_per_frame: None,
                compress: true,
            }
        }
    }

    /// `NEAR_SIGNER_QR_SESSION_ID` (8 hex digits) pins the session id, so a test can prepare the
    /// answer with `near-signer-sim optical` before the codes are shown. Unset in normal use.
    fn session_id_from_env() -> Option<u32> {
        let value = std::env::var("NEAR_SIGNER_QR_SESSION_ID").ok()?;
        u32::from_str_radix(value.trim(), 16).ok()
    }

    /// `NEAR_SIGNER_QR_FPS` (1–30) overrides the frame rate, for a terminal or a phone that can't
    /// keep up with the default, or to try a faster one.
    fn fps_from_env() -> Option<u32> {
        std::env::var("NEAR_SIGNER_QR_FPS")
            .ok()?
            .trim()
            .parse()
            .ok()
    }

    /// A session id nobody can predict well enough to answer a request they didn't see.
    pub fn random_session_id() -> u32 {
        let mut buffer = [0u8; 4];
        if std::fs::File::open("/dev/urandom")
            .and_then(|mut file| std::io::Read::read_exact(&mut file, &mut buffer))
            .is_ok()
        {
            return u32::from_be_bytes(buffer);
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let mixed = (now as u64) ^ (u64::from(std::process::id()) << 32) ^ 0x9E37_79B9_7F4A_7C15;
        (mixed ^ (mixed >> 29)).wrapping_mul(0xBF58_476D_1CE4_E5B9) as u32
    }

    /// (rows, columns) of the terminal on stdout: the window size from the kernel, else
    /// `tput`, else `LINES`/`COLUMNS`, else a small default.
    pub fn terminal_size() -> (usize, usize) {
        #[cfg(unix)]
        {
            let mut size = libc::winsize {
                ws_row: 0,
                ws_col: 0,
                ws_xpixel: 0,
                ws_ypixel: 0,
            };
            // SAFETY: TIOCGWINSZ writes a winsize struct, and that is what is passed.
            let ok = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut size) } == 0;
            if ok && size.ws_row > 0 && size.ws_col > 0 {
                return (usize::from(size.ws_row), usize::from(size.ws_col));
            }
        }
        let tput = |what: &str| -> Option<usize> {
            let output = std::process::Command::new("tput").arg(what).output().ok()?;
            String::from_utf8_lossy(&output.stdout)
                .trim()
                .parse()
                .ok()
                .filter(|&n| n > 0)
        };
        let env = |name: &str| -> Option<usize> { std::env::var(name).ok()?.parse().ok() };
        (
            tput("lines").or_else(|| env("LINES")).unwrap_or(40),
            tput("cols").or_else(|| env("COLUMNS")).unwrap_or(100),
        )
    }

    /// Shows the request's frames on standard output until the answer is typed on standard
    /// input, then returns it (with any status; the caller decides what a non-`9000` means).
    /// A line that isn't a response code, or answers another request, is reported and the
    /// waiting continues; the end of standard input cancels.
    /// How long a new window size must hold before the codes follow it: a drag resizes many
    /// times a second, and every change of height restarts the transfer on the phone.
    const RESIZE_SETTLE: Duration = Duration::from_millis(500);

    /// What a window makes of a transfer: how many codes at once, whether they loop, the lines
    /// under them, and the rows the whole block takes.
    struct Layout {
        per_frame: usize,
        animated: bool,
        below: Vec<String>,
        reserved: usize,
    }

    impl Layout {
        fn new(
            sender: &super::Sender,
            columns: usize,
            codes_per_frame: Option<usize>,
            invert: bool,
            note: Option<&str>,
            caption: Option<&str>,
        ) -> Layout {
            let first = render(&sender.frame(0), invert);
            let height = first.len();
            let code_width = first.first().map_or(0, |line| line.chars().count());
            // Never more codes than there are pieces: a request that fits one code is one code.
            let count = sender.fragment_count();
            let per_frame = codes_per_frame
                .unwrap_or_else(|| codes_side_by_side(columns, code_width))
                .clamp(1, 3)
                .min(count);
            // Every piece on screen at once stands still; more pieces than fit go round in a loop.
            let animated = count > per_frame;
            let mut below = Vec::new();
            if count > 1 {
                let shown = match (animated, per_frame) {
                    (false, _) => String::new(),
                    (true, 1) => ", one at a time in a loop".to_string(),
                    (true, n) => format!(", {n} at a time in a loop"),
                };
                below.push(format!(
                    "{count} codes{shown}; keep the phone on them until it has all {count}."
                ));
            }
            below.extend(note.map(str::to_string));
            below.extend(caption.map(str::to_string));
            below.push(INSTRUCTIONS.to_string());
            // Small codes mean a slow transfer; say what helps while it is on screen.
            if animated && sender.fragment_size() < 500 {
                below.push(HINT.to_string());
            }
            // The block above the prompt: codes, the lines under them, a blank line.
            let reserved = height + below.len() + 2;
            Layout {
                per_frame,
                animated,
                below,
                reserved,
            }
        }
    }

    /// The codes on screen, animating from a background thread, until `stop`. They are redrawn
    /// at the top of the screen around a saved cursor position, with `\r\n` line ends, so the
    /// cursor stays where the caller left it and a prompt can run under them while they animate,
    /// also a raw-mode line editor (near-cli-rs prompts with inquire). They follow the window:
    /// a resize that has settled re-lays them out, and a change of height re-cuts the request
    /// into pieces of the new size (the phone starts over), after which the screen is cleared
    /// and the cursor parked on the bottom row for the prompt to redraw itself there. `run` is
    /// the plain version: start, prompt, read lines, `parse`, `stop`.
    pub struct Session {
        output: Arc<Mutex<()>>,
        stop: Arc<AtomicBool>,
        animation: Option<std::thread::JoinHandle<()>>,
        session_id: u32,
    }

    impl Session {
        /// Clears the terminal and starts showing the request. Fails when stdout isn't a terminal.
        pub fn start(request: &Request, options: &Options) -> Result<Session, Error> {
            let stdout = std::io::stdout();
            if !stdout.is_terminal() {
                return Err(Error::Io(std::io::Error::other(
                    "standard output is not a terminal, so the QR codes can't be shown",
                )));
            }
            let session_id = options
                .session_id
                .or_else(session_id_from_env)
                .unwrap_or_else(random_session_id);
            let message = if options.compress {
                request.message_for_transfer()
            } else {
                request.message()
            };
            // Said on screen while it is sent: the saving is why a deployment is bearable.
            let note = (message.len() < request.message().len()).then(|| {
                format!(
                    "{} bytes, sent as {} compressed",
                    with_spaces(request.payload.len()),
                    with_spaces(message.len())
                )
            });
            let (rows, columns) = terminal_size();
            let fixed_fragment_size = options.fragment_size;
            let fragment_size = fixed_fragment_size.unwrap_or_else(|| fitting_fragment_size(rows));
            // Built here so a bad size fails the call; the thread rebuilds it on a resize.
            let sender = super::Sender::new(message.clone(), session_id, fragment_size)?;
            let invert = options.invert;
            let codes_per_frame = options.codes_per_frame;
            let caption = options.caption.clone();
            let fps = fps_from_env().unwrap_or(options.fps).clamp(1, 30);
            let period = Duration::from_millis(u64::from(1000 / fps));
            let output = Arc::new(Mutex::new(()));
            let stop = Arc::new(AtomicBool::new(false));

            let layout = Layout::new(
                &sender,
                columns,
                codes_per_frame,
                invert,
                note.as_deref(),
                caption.as_deref(),
            );
            {
                let _guard = output.lock().expect("output lock");
                let mut out = stdout.lock();
                write!(out, "\x1b[2J\x1b[H{}", "\r\n".repeat(layout.reserved))?;
                out.flush()?;
            }

            let animation = {
                let output = Arc::clone(&output);
                let stop = Arc::clone(&stop);
                std::thread::spawn(move || {
                    let mut sender = sender;
                    let mut layout = layout;
                    let mut size = (rows, columns);
                    let mut pending: Option<((usize, usize), Instant)> = None;
                    let mut sequence: u32 = 0;
                    let mut next_frame = Instant::now();
                    let mut drawn = false;
                    while !stop.load(Ordering::Relaxed) {
                        // Follow the window once a new size has held for RESIZE_SETTLE.
                        let now = terminal_size();
                        if now == size {
                            pending = None;
                        } else {
                            match pending {
                                Some((seen, since)) if seen == now => {
                                    if since.elapsed() >= RESIZE_SETTLE {
                                        size = now;
                                        pending = None;
                                        let wanted = fixed_fragment_size
                                            .unwrap_or_else(|| fitting_fragment_size(size.0));
                                        if wanted.min(sender.message_len())
                                            != sender.fragment_size()
                                        {
                                            if let Ok(resized) = super::Sender::new(
                                                message.clone(),
                                                session_id,
                                                wanted,
                                            ) {
                                                sender = resized;
                                                sequence = 0;
                                            }
                                        }
                                        layout = Layout::new(
                                            &sender,
                                            size.1,
                                            codes_per_frame,
                                            invert,
                                            note.as_deref(),
                                            caption.as_deref(),
                                        );
                                        drawn = false;
                                        // A clean screen; the prompt's owner redraws it from
                                        // the bottom row on the next key.
                                        let _guard = output.lock().expect("output lock");
                                        let mut out = std::io::stdout().lock();
                                        let _ = write!(out, "\x1b[2J\x1b[{};1H", size.0);
                                        let _ = out.flush();
                                    }
                                }
                                _ => pending = Some((now, Instant::now())),
                            }
                        }
                        if drawn && !layout.animated {
                            std::thread::sleep(period);
                            continue;
                        }
                        drawn = true;
                        let texts: Vec<String> = (0..layout.per_frame as u32)
                            .map(|offset| sender.frame(sequence.wrapping_add(offset)))
                            .collect();
                        let mut lines = render_row(&texts, invert);
                        lines.extend(layout.below.iter().cloned());
                        {
                            // One frame per write, inside synchronized output (DEC mode 2026): a
                            // frame is tens of kilobytes of block characters, and a terminal that
                            // painted part of it would flicker; terminals without the mode ignore
                            // it. Cursor saved and restored, so a line editor running under the
                            // codes keeps its place. `\r\n`, because raw mode (inquire) does not
                            // turn `\n` into a carriage return.
                            let _guard = output.lock().expect("output lock");
                            let mut out = std::io::stdout().lock();
                            let _ = write!(
                                out,
                                "\x1b[?2026h\x1b[s\x1b[H{}\x1b[K\r\n\x1b[u\x1b[?2026l",
                                lines.join("\x1b[K\r\n")
                            );
                            let _ = out.flush();
                        }
                        sequence = sequence.wrapping_add(layout.per_frame as u32);
                        next_frame += period;
                        if let Some(wait) = next_frame.checked_duration_since(Instant::now()) {
                            std::thread::sleep(wait);
                        }
                    }
                })
            };
            Ok(Session {
                output,
                stop,
                animation: Some(animation),
                session_id,
            })
        }

        pub fn session_id(&self) -> u32 {
            self.session_id
        }

        /// Waits for a line on stdin and returns it trimmed (empty for Enter alone). The end of
        /// the input is `Cancelled`.
        pub fn wait_for_enter(&self) -> Result<String, Error> {
            let mut line = String::new();
            if std::io::stdin().lock().read_line(&mut line)? == 0 {
                return Err(Error::Cancelled);
            }
            Ok(line.trim().to_string())
        }

        /// Typed text as the answer to this session's request.
        pub fn parse(&self, text: &str) -> Result<Response, Error> {
            parse_for(self.session_id, text)
        }

        /// Stops the codes and clears the screen, leaving the terminal quiet for a prompt.
        pub fn stop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            if let Some(animation) = self.animation.take() {
                let _ = animation.join();
                let _guard = self.output.lock().expect("output lock");
                let mut out = std::io::stdout().lock();
                let _ = write!(out, "\x1b[2J\x1b[H");
                let _ = out.flush();
            }
        }

        fn say(&self, text: &str) -> Result<(), Error> {
            let _guard = self.output.lock().expect("output lock");
            let mut out = std::io::stdout().lock();
            write!(out, "{text}")?;
            out.flush()?;
            Ok(())
        }
    }

    impl Drop for Session {
        fn drop(&mut self) {
            self.stop();
        }
    }

    fn parse_for(session_id: u32, text: &str) -> Result<Response, Error> {
        match Response::parse(text) {
            None => Err(Error::NotAResponse),
            Some(response) if response.session_id != session_id => Err(Error::OtherSession {
                expected: session_id,
                got: response.session_id,
            }),
            Some(response) => Ok(response),
        }
    }

    const INSTRUCTIONS: &str =
        "Phone: open NEAR Signer, tap \"Scan from computer\", point it here. \
                                Type or paste its answer below.";
    const HINT: &str =
        "A taller window or a smaller font (⌘-) gives bigger codes and a faster transfer.";

    /// 299834 as "299 834".
    pub fn with_spaces(n: usize) -> String {
        let digits = n.to_string();
        let mut out = String::with_capacity(digits.len() + digits.len() / 3);
        for (i, c) in digits.chars().enumerate() {
            if i > 0 && (digits.len() - i) % 3 == 0 {
                out.push(' ');
            }
            out.push(c);
        }
        out
    }

    /// Shows the request until the answer is typed under the codes, and returns it (any status).
    pub fn run(request: &Request, options: &Options) -> Result<Response, Error> {
        let mut session = Session::start(request, options)?;
        session.say("Code from the phone: ")?;
        loop {
            let line = session.wait_for_enter()?;
            if line.is_empty() {
                session.say("Code from the phone: ")?;
                continue;
            }
            match session.parse(&line) {
                Ok(response) => {
                    session.stop();
                    return Ok(response);
                }
                Err(problem) => {
                    session.say(&format!("{problem}. Try again.\r\nCode from the phone: "))?
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base45_matches_rfc_9285() {
        assert_eq!(base45::encode(b"AB"), "BB8");
        assert_eq!(base45::encode(b"Hello!!"), "%69 VD92EX0");
        assert_eq!(base45::encode(b"base-45"), "UJCLQE7W581");
        assert_eq!(base45::decode("QED8WEX0").unwrap(), b"ietf!");
        assert_eq!(base45::decode("%69 VD92EX0").unwrap(), b"Hello!!");
        assert_eq!(base45::decode("FGW").unwrap(), [0xFF, 0xFF]);
        assert!(base45::decode("GGW").is_none(), "a triplet above 65 535");
        assert!(base45::decode(":::").is_none());
        assert!(base45::decode("A").is_none(), "3n + 1 characters");
        assert!(
            base45::decode("ab").is_none(),
            "lower case is outside the alphabet"
        );
        for len in 0..40 {
            let bytes: Vec<u8> = (0..len).map(|i| (i * 37 + 11) as u8).collect();
            assert_eq!(base45::decode(&base45::encode(&bytes)).unwrap(), bytes);
        }
    }

    #[test]
    fn crc32_matches_zlib() {
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
        assert_eq!(crc32(b"hello"), 0x3610_A686);
        assert_eq!(crc32(b""), 0);
    }

    #[test]
    fn crockford_base32() {
        assert_eq!(base32::encode(b"foobar"), "CSQPYRK1E8");
        assert_eq!(base32::decode("CSQPYRK1E8").unwrap(), b"foobar");
        assert_eq!(base32::decode("csqpy rk1e8").unwrap(), b"foobar");
        assert_eq!(
            base32::decode("CSQPY-RKlE8").unwrap(),
            b"foobar",
            "L reads as 1"
        );
        assert_eq!(
            base32::decode("CSQPYRKIE8").unwrap(),
            b"foobar",
            "I reads as 1"
        );
        assert_eq!(
            base32::decode(&base32::encode(&[0, 0x0F])).unwrap(),
            [0, 0x0F]
        );
        assert_eq!(base32::decode("O0").unwrap(), [0], "O reads as 0");
        assert!(
            base32::decode("CSQPYRK1E9").is_none(),
            "padding bits must be zero"
        );
        assert!(base32::decode("U").is_none(), "U is not in the alphabet");
        for len in 0..40 {
            let bytes: Vec<u8> = (0..len).map(|i| (i * 53 + 7) as u8).collect();
            assert_eq!(base32::decode(&base32::encode(&bytes)).unwrap(), bytes);
        }
    }

    #[test]
    fn base58_and_base64() {
        let key = base58::decode("EHk3HArKPRpX7564aTMD7VJdbQRoWA9JvJaEvbta2iSz").unwrap();
        assert_eq!(key.len(), 32);
        assert_eq!(
            base58::encode(&key),
            "EHk3HArKPRpX7564aTMD7VJdbQRoWA9JvJaEvbta2iSz"
        );
        assert_eq!(base58::encode(&[0, 0, 1]), "112");
        assert_eq!(base58::decode("112").unwrap(), [0, 0, 1]);
        assert!(base58::decode("0").is_none());
        assert_eq!(base64::encode(b"hello"), "aGVsbG8=");
        assert_eq!(base64::encode(b""), "");
        assert_eq!(base64::decode("aGVsbG8=").unwrap(), b"hello");
        assert_eq!(base64::decode("aGVsbG8").unwrap(), b"hello");
        assert!(base64::decode("a").is_none());
        for len in 0..30 {
            let bytes: Vec<u8> = (0..len).map(|i| (i * 91 + 3) as u8).collect();
            assert_eq!(base64::decode(&base64::encode(&bytes)).unwrap(), bytes);
        }
    }

    #[test]
    fn fountain_indexes_match_the_other_implementations() {
        assert_eq!(fountain_indexes(0x12345678, 10, 7), [1, 2]);
        assert_eq!(fountain_indexes(1, 1000, 300), [130, 181, 258]);
        assert_eq!(
            fountain_indexes(5, 3, 7),
            [3],
            "below K, the fragment itself"
        );
        assert_eq!(
            fountain_indexes(5, 17, 7),
            [3],
            "even blocks repeat the fragments"
        );
        assert_eq!(fountain_indexes(7, 538, 4), [2]);
        assert!(fountain_indexes(5, 10, 7).len() > 1, "odd blocks mix");
        let expected: [&[usize]; 12] = [
            &[0, 6],
            &[1, 7, 14],
            &[6, 16, 7],
            &[16, 11],
            &[
                16, 5, 4, 7, 13, 18, 11, 17, 1, 9, 0, 2, 6, 3, 12, 8, 19, 15, 14, 10,
            ],
            &[5, 19, 17],
            &[0, 17],
            &[4, 14],
            &[5, 7, 9],
            &[10, 12],
            &[9, 1, 2],
            &[12, 0],
        ];
        for (offset, indexes) in expected.iter().enumerate() {
            assert_eq!(
                fountain_indexes(0xDEAD_BEEF, 20 + offset as u32, 20),
                *indexes,
                "sequence {}",
                20 + offset
            );
        }
        for sequence in 0..2000u32 {
            let indexes = fountain_indexes(7, sequence, 13);
            assert!(!indexes.is_empty() && indexes.len() <= 13);
            let distinct: HashSet<usize> = indexes.iter().copied().collect();
            assert_eq!(distinct.len(), indexes.len(), "no fragment twice");
            assert!(indexes.iter().all(|&i| i < 13));
        }
    }

    #[test]
    fn frame_texts_match_the_other_implementations() {
        let sender = Sender::new(b"hello".to_vec(), 0x0102_0304, 4).unwrap();
        assert_eq!(sender.fragment_count(), 2);
        assert_eq!(sender.frame(0), "NS1:W50KB0YM0000KS0/N0W42E.G000E20: CI2");
        assert_eq!(sender.frame(1), "NS1:W50KB0YM0000KS0/N0W42E.G00078000000");
        let frame = Frame::parse(&sender.frame(0)).unwrap();
        assert_eq!(
            (
                frame.session_id,
                frame.length,
                frame.fragment_size,
                frame.crc,
                frame.sequence
            ),
            (0x0102_0304, 5, 4, 0x3610_A686, 0)
        );
        assert_eq!(frame.data, b"hell");
        assert!(
            Frame::parse("NS1:W50KB0YM0000KS0/N0W42E.G000E20: CI").is_none(),
            "a byte missing"
        );
        assert!(Frame::parse("ns1:W50KB0YM0000KS0/N0W42E.G000E20: CI2").is_none());
        assert!(Frame::parse("https://example.com").is_none());
        assert!(Frame::parse("").is_none());

        // A short message is one fragment of its own length.
        let short = Sender::new(vec![1, 2, 3], 9, 500).unwrap();
        assert_eq!((short.fragment_count(), short.fragment_size()), (1, 3));
        assert!(matches!(
            Sender::new(vec![], 1, 10),
            Err(Error::MessageTooLong(0))
        ));
        assert!(matches!(
            Sender::new(vec![0; MAX_MESSAGE_LENGTH + 1], 1, 10),
            Err(Error::MessageTooLong(_))
        ));
        assert!(matches!(
            Sender::new(vec![0; 10], 1, 0),
            Err(Error::FragmentSize(0))
        ));
        assert!(matches!(
            Sender::new(vec![0; 10], 1, 1201),
            Err(Error::FragmentSize(1201))
        ));
        assert!(matches!(
            Sender::new(vec![0; 70_000], 1, 1),
            Err(Error::TooManyFragments(70_000))
        ));
    }

    fn message(len: usize) -> Vec<u8> {
        (0..len)
            .map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8)
            .collect()
    }

    /// Feeds every frame the filter keeps, from `start`, until the receiver completes.
    fn transfer(
        sender: &Sender,
        receiver: &mut Receiver,
        start: u32,
        keep: impl Fn(u32) -> bool,
    ) -> (Vec<u8>, u32) {
        let mut sequence = start;
        loop {
            if keep(sequence) {
                match receiver.receive(&sender.frame(sequence)) {
                    Outcome::Complete(message) => return (message, sequence),
                    Outcome::Invalid(reason) => panic!("invalid: {reason}"),
                    _ => {}
                }
            }
            sequence += 1;
            assert!(sequence < start + 100_000, "did not complete");
        }
    }

    #[test]
    fn frames_in_order() {
        let bytes = message(1234);
        let sender = Sender::new(bytes.clone(), 42, 100).unwrap();
        let mut receiver = Receiver::new();
        for sequence in 0..12 {
            match receiver.receive(&sender.frame(sequence)) {
                Outcome::Progress(progress) => assert_eq!(
                    (progress.known, progress.total, progress.length),
                    (sequence as usize + 1, 13, 1234)
                ),
                other => panic!("{other:?}"),
            }
        }
        assert_eq!(
            receiver.receive(&sender.frame(12)),
            Outcome::Complete(bytes)
        );
        assert_eq!(receiver.session_id(), Some(42));
        assert_eq!(
            receiver.receive(&sender.frame(13)),
            Outcome::Duplicate,
            "done: nothing more to learn"
        );
        assert_eq!(receiver.receive("hello"), Outcome::NotAFrame);
    }

    #[test]
    fn lossy_starting_mid_stream() {
        let bytes = message(5000);
        let sender = Sender::new(bytes.clone(), 0xC0FFEE, 120).unwrap();
        let mut receiver = Receiver::new();
        let mut state = 99u32;
        let mut kept = Vec::with_capacity(10_000);
        for _ in 0..10_000 {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            kept.push(state % 10 >= 4);
        }
        let (received, last) = transfer(&sender, &mut receiver, 17, |s| kept[s as usize]);
        assert_eq!(received, bytes);
        assert!(
            last < 17 + 3 * sender.fragment_count() as u32,
            "fountain frames fill the gaps quickly"
        );
    }

    #[test]
    fn single_fragment_message() {
        let sender = Sender::new(b"k".to_vec(), 3, 100).unwrap();
        let mut receiver = Receiver::new();
        assert_eq!(
            receiver.receive(&sender.frame(5)),
            Outcome::Complete(b"k".to_vec()),
            "any frame of a K = 1 message is the message"
        );
    }

    #[test]
    fn large_message_with_losses() {
        let bytes = message(300 * 1024);
        let sender = Sender::new(bytes.clone(), 1, 500).unwrap();
        let mut receiver = Receiver::new();
        let (received, _) = transfer(&sender, &mut receiver, 0, |s| s % 5 != 2);
        assert_eq!(received, bytes);
    }

    /// The degree `fountain_indexes` draws first, without the shuffle: finding rare frames that
    /// mix tens of thousands of fragments takes millions of draws.
    fn fountain_degree(session_id: u32, sequence: u32, fragment_count: usize) -> usize {
        if (sequence / fragment_count as u32) % 2 == 0 {
            return 1;
        }
        let mut state = session_id ^ sequence.wrapping_mul(0x9E37_79B9);
        if state == 0 {
            state = 0x9E37_79B9;
        }
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        let u = u64::from(state);
        ((u64::from(u32::MAX) / ((1u64 << 32) - u)) as usize + 1).min(fragment_count)
    }

    /// A hostile screen declares 65 535 one-byte fragments and shows mixed frames that mix tens
    /// of thousands of them: each kept frame costs a set that size, and 4096 kept frames would be
    /// gigabytes. The budget of unknown indexes (16 per fragment) evicts the oldest instead;
    /// frames that mix a few fragments are still kept. (Shown at K = 8192, which is faster; the
    /// budget scales with K.)
    #[test]
    fn mixed_frames_are_bounded_by_their_unknown_indexes() {
        let count = 8192;
        let budget = HELD_INDEXES_PER_FRAGMENT * count;
        let sender = Sender::new(vec![0x5A; count], 77, 1).unwrap();
        let mut receiver = Receiver::new();
        // 40 frames of more than 4096 fragments each: together over the budget.
        let mut fed = 0;
        let wide = (count as u32..)
            .filter(|&sequence| fountain_degree(77, sequence, count) > 4096)
            .take(40);
        for (number, sequence) in wide.enumerate() {
            let degree = fountain_degree(77, sequence, count);
            assert_eq!(fountain_indexes(77, sequence, count).len(), degree);
            receiver.receive(&sender.frame(sequence));
            fed += degree;
            assert!(receiver.held_indexes() <= budget, "frame {number}");
        }
        assert!(fed > budget, "the frames fed exceed the budget");
        let narrow = (count as u32..)
            .filter(|&sequence| (2..=8).contains(&fountain_degree(77, sequence, count)))
            .take(20);
        for sequence in narrow {
            receiver.receive(&sender.frame(sequence));
        }
        assert!(receiver.held_indexes() > 0, "narrow frames are kept");
        assert!(receiver.held_indexes() <= budget);
    }

    #[test]
    fn checksum_mismatch_and_disagreeing_frames() {
        let sender = Sender::new(message(50), 8, 10).unwrap();
        let mut receiver = Receiver::new();
        // A frame whose data was altered in flight: the CRC catches it at the end.
        for sequence in 0..4 {
            receiver.receive(&sender.frame(sequence));
        }
        let mut last = Frame::parse(&sender.frame(4)).unwrap();
        last.data[0] ^= 1;
        assert!(
            matches!(receiver.receive(&last.text()), Outcome::Invalid(reason) if reason.contains("checksum"))
        );
        assert!(receiver.progress().is_none(), "the receiver started over");
        // A frame of the same session with another length.
        receiver.receive(&sender.frame(0));
        let mut other = Frame::parse(&sender.frame(1)).unwrap();
        other.length = 49;
        assert!(
            matches!(receiver.receive(&other.text()), Outcome::Invalid(reason) if reason.contains("disagree"))
        );
    }

    #[test]
    fn another_session_takes_over_after_three_frames() {
        let first = Sender::new(message(40), 1, 10).unwrap();
        let second = Sender::new(message(30), 2, 10).unwrap();
        let mut receiver = Receiver::new();
        receiver.receive(&first.frame(0));
        assert_eq!(receiver.receive(&second.frame(0)), Outcome::OtherSession);
        assert_eq!(receiver.receive(&second.frame(1)), Outcome::OtherSession);
        receiver.receive(&first.frame(1));
        assert_eq!(
            receiver.receive(&second.frame(0)),
            Outcome::OtherSession,
            "the count starts over after a frame of the current session"
        );
        assert_eq!(receiver.receive(&second.frame(1)), Outcome::OtherSession);
        assert!(
            matches!(receiver.receive(&second.frame(2)), Outcome::Progress(progress) if progress.session_id == 2 && progress.known == 1)
        );
        assert_eq!(receiver.session_id(), Some(2));
    }

    #[test]
    fn frames_of_a_transfer_render_to_the_same_height() {
        let message: Vec<u8> = (0..700u32).map(|i| (i * 7 % 251) as u8).collect();
        let sender = Sender::new(message, 0x1234_5678, 300).unwrap();
        let heights: HashSet<usize> = (0..24)
            .map(|s| terminal::render(&sender.frame(s), false).len())
            .collect();
        assert_eq!(heights.len(), 1, "heights {heights:?}");
    }

    #[test]
    fn compressed_requests() {
        let path = "m/44'/397'/0'/0'/1'";
        // Repetitive bytes, like contract code: compressed.
        let payload: Vec<u8> = (0..20_000u32).map(|i| (i % 37) as u8).collect();
        let request = Request::new(Kind::Transaction, path, payload.clone()).unwrap();
        let sent = request.message_for_transfer();
        assert_eq!(sent[0], 0x02 | 0x80);
        assert!(sent.len() < payload.len() / 4, "{} bytes sent", sent.len());
        assert_eq!(read_u32(&sent, 21) as usize, payload.len());
        assert_eq!(Request::parse(&sent).unwrap(), request);
        assert_eq!(Request::parse(&request.message()).unwrap(), request);
        assert_eq!(request.digest(), Request::parse(&sent).unwrap().digest());

        // Too small to bother, incompressible, or a public key: the plain message.
        let small = Request::new(Kind::Transaction, path, vec![7; 40]).unwrap();
        assert_eq!(small.message_for_transfer(), small.message());
        let mut state = 0x1234_5678u32;
        let noise: Vec<u8> = (0..2_000)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                (state >> 24) as u8
            })
            .collect();
        let random = Request::new(Kind::Nep413, path, noise).unwrap();
        assert_eq!(random.message_for_transfer(), random.message());
        let key = Request::new(Kind::PublicKey, path, vec![]).unwrap();
        assert_eq!(key.message_for_transfer(), key.message());

        // The length field must match what inflates, and the stream must be whole.
        let mut wrong_length = sent.clone();
        wrong_length[24] = wrong_length[24].wrapping_add(1);
        assert!(Request::parse(&wrong_length).is_none());
        let mut zero = sent.clone();
        zero[21..25].copy_from_slice(&[0, 0, 0, 0]);
        assert!(Request::parse(&zero).is_none());
        let mut huge = sent.clone();
        huge[21..25].copy_from_slice(&(MAX_PAYLOAD_LENGTH as u32 + 1).to_be_bytes());
        assert!(Request::parse(&huge).is_none());
        let truncated = &sent[..sent.len() - 3];
        assert!(Request::parse(truncated).is_none());
        let mut key_flagged = key.message();
        key_flagged[0] |= 0x80;
        key_flagged.extend_from_slice(&[0, 0, 0, 1, 0x4b, 0x04, 0x00]);
        assert!(Request::parse(&key_flagged).is_none());

        // Raw DEFLATE as zlib (Python, wbits -15) and flate2 produce it.
        let hello = b"hello hello hello hello hello!";
        let from_zlib = [
            0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0xc8, 0xc0, 0x4e, 0x2a, 0x02, 0x00,
        ];
        assert_eq!(inflate_exact(&from_zlib, hello.len()).unwrap(), hello);
        assert_eq!(inflate_exact(&deflate(hello), hello.len()).unwrap(), hello);
        assert!(inflate_exact(&from_zlib, hello.len() - 1).is_none());
        assert!(inflate_exact(&from_zlib, hello.len() + 1).is_none());
    }

    #[test]
    fn request_message() {
        let request =
            Request::new(Kind::Transaction, "m/44'/397'/0'/0'/1'", vec![1, 2, 3]).unwrap();
        assert_eq!(
            request.path,
            [
                44 | HARDENED,
                397 | HARDENED,
                HARDENED,
                HARDENED,
                1 | HARDENED
            ]
        );
        assert_eq!(request.path_string(), "m/44'/397'/0'/0'/1'");
        let message = request.message();
        assert_eq!(message.len(), 24);
        assert_eq!(message[0], 0x02);
        assert_eq!(&message[1..5], &[0x80, 0, 0, 44]);
        assert_eq!(Request::parse(&message).unwrap(), request);
        assert_eq!(
            Request::new(Kind::PublicKey, "44'/397'/0'/0'/1'", vec![])
                .unwrap()
                .path,
            request.path
        );
        assert!(
            Request::new(Kind::PublicKey, "44'/397'/0'/0'", vec![]).is_err(),
            "four levels"
        );
        assert!(
            Request::new(Kind::PublicKey, "44'/397'/0'/0'/1", vec![]).is_err(),
            "unhardened"
        );
        assert!(
            Request::new(Kind::PublicKey, "44'/60'/0'/0'/1'", vec![]).is_err(),
            "another coin"
        );
        assert!(
            Request::new(Kind::PublicKey, "44'/397'/0'/0'/1'/2'", vec![]).is_err(),
            "six levels"
        );
        assert!(Request::parse(&message[..20]).is_none(), "too short");
        let mut unknown = message.clone();
        unknown[0] = 0x05;
        assert!(Request::parse(&unknown).is_none());
        let mut bad_path = message.clone();
        bad_path[4] = 60;
        assert!(Request::parse(&bad_path).is_none());
        let mut key_with_payload = message.clone();
        key_with_payload[0] = 0x04;
        assert!(Request::parse(&key_with_payload).is_none());
        assert!(Request::parse(&key_with_payload[..21]).is_some());
        assert_eq!(
            Request::parse(&key_with_payload[..21]).unwrap().kind,
            Kind::PublicKey
        );
    }

    #[test]
    fn digests() {
        let tx = base64::decode("DQAAAGFsaWNlLnRlc3RuZXQAxXHjPi42wsco1hfqd6iOIyDIaX6si0Y638ASi5aCXL8HAAAAAAAAAAsAAABib2IudGVzdG5ldDlKvrNecHYJ3o9ztj1DvRo3b/5nk1yqaJN90pvATmc8AQAAAAMAAIBxZDO2KaM9AQAAAAAA").unwrap();
        let request = Request::new(Kind::Transaction, "44'/397'/0'/0'/1'", tx.clone()).unwrap();
        assert_eq!(
            base58::encode(&request.digest().unwrap()),
            "Dt14S8X7ZntGvTjsmRmjQ6ZEbGFoqcZVxGpGqi1ikBAq"
        );
        let public_key: [u8; 32] = base58::decode("EHk3HArKPRpX7564aTMD7VJdbQRoWA9JvJaEvbta2iSz")
            .unwrap()
            .try_into()
            .unwrap();
        let signature: [u8; 64] = base64::decode("DnGwAHP7kQdyzgm8pZcl5J5d+IRvq7qCrMPVBzzC+7lnUkgttnTBJyfJW7eKuG1PebXsQytUTPNfVurd1BlSBg==")
            .unwrap()
            .try_into()
            .unwrap();
        assert!(verify(&public_key, &request.digest().unwrap(), &signature));
        let mut wrong = signature;
        wrong[0] ^= 1;
        assert!(!verify(&public_key, &request.digest().unwrap(), &wrong));
        assert!(Request::new(Kind::PublicKey, "44'/397'/0'/0'/1'", vec![])
            .unwrap()
            .digest()
            .is_none());
        // The NEP prefixes go in front of the payload.
        use sha2::Digest;
        let nep413 = Request::new(Kind::Nep413, "44'/397'/0'/0'/1'", vec![9, 9]).unwrap();
        assert_eq!(
            nep413.digest().unwrap(),
            <[u8; 32]>::from(sha2::Sha256::digest([0x9d, 0x01, 0x00, 0x80, 9, 9]))
        );
        let nep366 = Request::new(Kind::Nep366, "44'/397'/0'/0'/1'", vec![9, 9]).unwrap();
        assert_eq!(
            nep366.digest().unwrap(),
            <[u8; 32]>::from(sha2::Sha256::digest([0x6e, 0x01, 0x00, 0x40, 9, 9]))
        );
    }

    #[test]
    fn response_text() {
        let response = Response {
            session_id: 0x0102_0304,
            status: 0x9000,
            result: vec![7; 64],
        };
        let text = response.text();
        assert_eq!(text, "080G40R4J000E1R70W3GE1R70W3GE1R70W3GE1R70W3GE1R70W3GE1R70W3GE1R70W3GE1R70W3GE1R70W3GE1R70W3GE1R70W3GE1R70W3GE1R70ZC9V3V2");
        assert_eq!(Response::parse(&text).unwrap(), response);
        assert_eq!(Response::parse(&response.grouped()).unwrap(), response);
        assert_eq!(Response::parse(&text.to_lowercase()).unwrap(), response);
        assert_eq!(response.grouped().split(' ').count(), 24);
        assert_eq!(response.signature(), Some([7; 64]));
        assert_eq!(response.public_key(), None);
        let mut typo = text.clone();
        typo.replace_range(10..11, if &text[10..11] == "A" { "B" } else { "A" });
        assert!(
            Response::parse(&typo).is_none(),
            "the checksum catches a typo"
        );
        assert!(Response::parse(&format!("NS1:{text}")).is_none());
        assert!(Response::parse("").is_none());

        let refused = Response {
            session_id: 9,
            status: 0xB00D,
            result: vec![],
        };
        assert_eq!(Response::parse(&refused.text()).unwrap(), refused);
        assert_eq!(
            refused.status_message(),
            "the transaction's key is not the phone's key at that path"
        );
        assert_eq!(refused.signature(), None);
        let key = Response {
            session_id: 9,
            status: 0x9000,
            result: vec![1; 32],
        };
        assert_eq!(key.public_key(), Some([1; 32]));
        assert_eq!(key.signature(), None);
    }

    #[test]
    fn terminal_rendering() {
        let lines = terminal::render("NS1:W50KB0YM0000KS0/N0W42E.G000E20: CI2", false);
        // 25 modules (version 2) plus 2 quiet modules each side, two rows per line.
        assert_eq!(lines.len(), (25 + 4) / 2 + 1);
        assert!(lines.iter().all(|line| line.chars().count() == 29));
        assert!(
            lines[0].chars().all(|c| c == '█'),
            "the quiet zone is light"
        );
        let inverted = terminal::render("NS1:W50KB0YM0000KS0/N0W42E.G000E20: CI2", true);
        assert!(inverted[0].chars().all(|c| c == ' '));
        assert_eq!(terminal::fitting_fragment_size(200), 1200);
        assert_eq!(terminal::fitting_fragment_size(10), 50);
        assert_eq!(
            terminal::fitting_fragment_size(45),
            300,
            "a 35-line code plus 7 lines"
        );
        assert_eq!(terminal::fitting_fragment_size(30), 80);
        assert_eq!(terminal::codes_side_by_side(180, 69), 2);
        assert_eq!(terminal::codes_side_by_side(100, 121), 1);
        assert_eq!(terminal::codes_side_by_side(400, 61), 3);
    }
}
