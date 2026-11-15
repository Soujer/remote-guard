using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Threading.Tasks;
#pragma warning disable 1691, 1692
#pragma warning disable SYSLIB0060 // Framework 4.8 compatibility: the static PBKDF2 API is unavailable there.

namespace RemoteGuard {
    public static class MediaProgress {
        public static double Duration(string progress) {
            double result=0;
            foreach(string line in progress.Split('\n')) {
                double value;
                if(line.StartsWith("out_time_us=",StringComparison.Ordinal) && Double.TryParse(line.Substring(12).Trim(),System.Globalization.NumberStyles.Float,System.Globalization.CultureInfo.InvariantCulture,out value)) result=Math.Max(result,value/1000000);
            }
            return result;
        }
    }
    // v1: magic(8), wrapped-key length(4 LE), RSA-OAEP-SHA256(AES key || MAC key),
    // IV(16), AES-256-CBC ciphertext, HMAC-SHA256(header || ciphertext).
    public static class Vault {
        public static string PasswordError(string password, string confirmation) {
            if (String.IsNullOrEmpty(password)) return "请输入私钥密码（至少 12 位）";
            if (password.Length < 12) return "私钥密码不足 12 位，当前为 " + password.Length + " 位";
            if (String.IsNullOrEmpty(confirmation)) return "请在右侧确认密码框再次输入密码";
            if (!String.Equals(password, confirmation, StringComparison.Ordinal)) return "两次输入的密码不一致，请重新确认";
            return null;
        }
        internal static byte[] Random(int size) {
            byte[] bytes = new byte[size];
            using (var rng = RandomNumberGenerator.Create()) rng.GetBytes(bytes);
            return bytes;
        }
        internal static byte[] Read(BinaryReader reader, int length) {
            byte[] bytes = reader.ReadBytes(length);
            if (bytes.Length != length) throw new InvalidDataException("Truncated encrypted file");
            return bytes;
        }
        static bool Equal(byte[] a, byte[] b) {
            int diff = a.Length ^ b.Length;
            for (int i = 0; i < Math.Min(a.Length, b.Length); i++) diff |= a[i] ^ b[i];
            return diff == 0;
        }
        internal static byte[] Part(byte[] value, int offset) {
            byte[] result = new byte[32]; Buffer.BlockCopy(value, offset, result, 0, 32); return result;
        }
        public static string CreateKey(string path, string password) {
            if (password == null || password.Length < 12) throw new ArgumentException("Use at least 12 password characters");
            using (var rsa = new RSACng(3072)) {
                byte[] salt = Random(16), iv = Random(16), material;
                using (var kdf = new Rfc2898DeriveBytes(password, salt, 210000, HashAlgorithmName.SHA256)) material = kdf.GetBytes(64);
                try {
                    using (var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    using (var mac = new HMACSHA256(Part(material, 32)))
                    using (var sink = new MacSink(output, mac, 1024 * 1024))
                    using (var aes = Aes.Create()) {
                        sink.Write(Encoding.ASCII.GetBytes("RGKEY001"), 0, 8);
                        sink.Write(salt, 0, salt.Length); sink.Write(iv, 0, iv.Length);
                        aes.Key = Part(material, 0); aes.IV = iv;
                        byte[] xml = Encoding.UTF8.GetBytes(rsa.ToXmlString(true));
                        try {
                            using (var crypto = new CryptoStream(sink, aes.CreateEncryptor(), CryptoStreamMode.Write, true)) {
                                crypto.Write(xml, 0, xml.Length); crypto.FlushFinalBlock();
                            }
                        } finally { Array.Clear(xml, 0, xml.Length); }
                        mac.TransformFinalBlock(new byte[0], 0, 0); output.Write(mac.Hash, 0, 32);
                    }
                    return rsa.ToXmlString(false);
                } finally { Array.Clear(material, 0, material.Length); }
            }
        }
        static string ReadKey(string path, string password) {
            var info = new FileInfo(path);
            if (info.Length < 88 || info.Length > 1024 * 1024) throw new InvalidDataException("Invalid key file");
            byte[] bytes = File.ReadAllBytes(path);
            if (Encoding.ASCII.GetString(bytes, 0, 8) != "RGKEY001") throw new InvalidDataException("Unsupported key format");
            byte[] salt = new byte[16], iv = new byte[16], material;
            Buffer.BlockCopy(bytes, 8, salt, 0, 16); Buffer.BlockCopy(bytes, 24, iv, 0, 16);
            using (var kdf = new Rfc2898DeriveBytes(password, salt, 210000, HashAlgorithmName.SHA256)) material = kdf.GetBytes(64);
            try {
                using (var mac = new HMACSHA256(Part(material, 32))) {
                    byte[] expected = mac.ComputeHash(bytes, 0, bytes.Length - 32), actual = new byte[32];
                    Buffer.BlockCopy(bytes, bytes.Length - 32, actual, 0, 32);
                    if (!Equal(expected, actual)) throw new CryptographicException("Wrong key password or damaged key file");
                }
                using (var aes = Aes.Create()) {
                    aes.Key = Part(material, 0); aes.IV = iv;
                    byte[] xml = aes.CreateDecryptor().TransformFinalBlock(bytes, 40, bytes.Length - 72);
                    try { return Encoding.UTF8.GetString(xml); } finally { Array.Clear(xml, 0, xml.Length); }
                }
            } finally { Array.Clear(material, 0, material.Length); }
        }
        // Authentication is completed before a single plaintext byte is released.
        public static void Decrypt(string input, string keyFile, string password, Stream output) {
            using (var file = new FileStream(input, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var reader = new BinaryReader(file, Encoding.UTF8, true))
            using (var rsa = new RSACng()) {
                if (Encoding.ASCII.GetString(Read(reader, 8)) != "RGREC001") throw new InvalidDataException("Unsupported recording format");
                int length = reader.ReadInt32();
                if (length < 256 || length > 1024) throw new InvalidDataException("Invalid key length");
                byte[] wrapped = Read(reader, length), iv = Read(reader, 16);
                long start = file.Position, cipherLength = file.Length - start - 32;
                if (cipherLength <= 0 || cipherLength % 16 != 0) throw new InvalidDataException("Incomplete recording");
                rsa.FromXmlString(ReadKey(keyFile, password));
                byte[] material = rsa.Decrypt(wrapped, RSAEncryptionPadding.OaepSHA256);
                try {
                    if (material.Length != 64) throw new CryptographicException("Invalid wrapped key");
                    using (var mac = new HMACSHA256(Part(material, 32))) {
                        file.Position = 0; byte[] buffer = new byte[65536]; long remaining = file.Length - 32;
                        while (remaining > 0) {
                            int n = file.Read(buffer, 0, (int)Math.Min(remaining, buffer.Length));
                            if (n == 0) throw new EndOfStreamException();
                            mac.TransformBlock(buffer, 0, n, buffer, 0); remaining -= n;
                        }
                        mac.TransformFinalBlock(new byte[0], 0, 0);
                        if (!Equal(mac.Hash, Read(reader, 32))) throw new CryptographicException("Wrong key or damaged recording");
                    }
                    file.Position = start;
                    using (var aes = Aes.Create()) {
                        aes.Key = Part(material, 0); aes.IV = iv;
                        using (var crypto = new CryptoStream(output, aes.CreateDecryptor(), CryptoStreamMode.Write, true)) {
                            byte[] buffer = new byte[65536]; long remaining = cipherLength;
                            while (remaining > 0) {
                                int n = file.Read(buffer, 0, (int)Math.Min(remaining, buffer.Length));
                                if (n == 0) throw new EndOfStreamException();
                                crypto.Write(buffer, 0, n); remaining -= n;
                            }
                            crypto.FlushFinalBlock();
                        }
                    }
                } finally { Array.Clear(material, 0, material.Length); }
            }
        }
        public static void Play(string input, string keyFile, string password, string player) {
            using (var process = new Process()) {
                process.StartInfo = new ProcessStartInfo(player, "-hide_banner -loglevel error -autoexit -i pipe:0") {
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
                    RedirectStandardError = true
                };
                process.Start(); var error = process.StandardError.ReadToEndAsync();
                try {
                    Decrypt(input, keyFile, password, process.StandardInput.BaseStream);
                    process.StandardInput.Close(); process.WaitForExit();
                    if (process.ExitCode != 0) throw new IOException("Player could not play this recording");
                } finally { if (!process.HasExited) process.Kill(); }
            }
        }
    }
    internal sealed class MacSink : Stream {
        readonly Stream file; readonly HMACSHA256 mac; readonly long maximum;
        public MacSink(Stream file, HMACSHA256 mac, long maximum) { this.file = file; this.mac = mac; this.maximum = maximum; }
        public override void Write(byte[] buffer, int offset, int count) {
            if (file.Position + count + 32 > maximum) throw new IOException("Encrypted segment size limit reached");
            mac.TransformBlock(buffer, offset, count, buffer, offset); file.Write(buffer, offset, count);
        }
        public override void Flush() { file.Flush(); }
        public override bool CanRead { get { return false; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return true; } }
        public override long Length { get { return file.Length; } }
        public override long Position { get { return file.Position; } set { throw new NotSupportedException(); } }
        public override int Read(byte[] b, int o, int c) { throw new NotSupportedException(); }
        public override long Seek(long o, SeekOrigin s) { throw new NotSupportedException(); }
        public override void SetLength(long n) { throw new NotSupportedException(); }
    }
    public sealed class RecordingWriter : IDisposable {
        readonly FileStream file; readonly HMACSHA256 mac; readonly Aes aes; readonly CryptoStream crypto;
        bool complete;
        public RecordingWriter(string path, string publicKey, long maximum) {
            byte[] material = Vault.Random(64), wrapped;
            try {
                using (var rsa = new RSACng()) { rsa.FromXmlString(publicKey); wrapped = rsa.Encrypt(material, RSAEncryptionPadding.OaepSHA256); }
                aes = Aes.Create(); aes.Key = Vault.Part(material, 0); aes.GenerateIV();
                mac = new HMACSHA256(Vault.Part(material, 32));
            } finally { Array.Clear(material, 0, material.Length); }
            file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
            var sink = new MacSink(file, mac, maximum);
            byte[] magic = Encoding.ASCII.GetBytes("RGREC001"), size = BitConverter.GetBytes(wrapped.Length);
            sink.Write(magic, 0, 8); sink.Write(size, 0, 4); sink.Write(wrapped, 0, wrapped.Length); sink.Write(aes.IV, 0, 16);
            crypto = new CryptoStream(sink, aes.CreateEncryptor(), CryptoStreamMode.Write, true);
        }
        public void Write(byte[] bytes, int count) { crypto.Write(bytes, 0, count); }
        public void Complete() {
            if (complete) return;
            crypto.FlushFinalBlock(); mac.TransformFinalBlock(new byte[0], 0, 0);
            file.Write(mac.Hash, 0, 32); file.Flush(true); complete = true;
        }
        public void Dispose() {
            // Failed writers remain .partial and must never be advertised as authenticated recordings.
            try { crypto.Dispose(); } finally { file.Dispose(); aes.Dispose(); mac.Dispose(); }
        }
    }
    public sealed class Capture : IDisposable {
        readonly Process process; readonly Task pump; readonly Task<string> errors;
        public bool Done { get { return pump.IsCompleted || process.HasExited; } }
        public double DurationSeconds { get; private set; }
        public Capture(string executable, string arguments, string publicKey, string path, long maximum) {
            process = new Process();
            process.StartInfo = new ProcessStartInfo(executable, arguments) { UseShellExecute = false,
                CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
            if (!process.Start()) throw new IOException("Cannot start FFmpeg");
            errors = process.StandardError.ReadToEndAsync();
            pump = Task.Run(() => {
                try {
                    using (var writer = new RecordingWriter(path, publicKey, maximum)) {
                        byte[] buffer = new byte[65536]; int n;
                        while ((n = process.StandardOutput.BaseStream.Read(buffer, 0, buffer.Length)) > 0) writer.Write(buffer, n);
                        writer.Complete();
                    }
                } catch { if (!process.HasExited) process.Kill(); throw; }
            });
        }
        public void Finish() {
            if (!process.HasExited) {
                try { process.StandardInput.WriteLine("q"); process.StandardInput.Flush(); } catch (IOException) { }
                if (!process.WaitForExit(5000)) process.Kill();
            }
            if (!pump.Wait(10000)) throw new IOException("Encryption worker did not finish");
            process.WaitForExit();
            if (process.ExitCode != 0) throw new IOException("FFmpeg failed: " + errors.Result);
            DurationSeconds = MediaProgress.Duration(errors.Result);
        }
        public void Dispose() {
            try { if (!process.HasExited) process.Kill(); pump.Wait(10000); }
            finally { process.Dispose(); }
        }
    }
}
