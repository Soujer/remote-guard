using System;
using System.IO;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteGuard {
    // Raw BGRA frames are decoded from the authenticated plaintext pipe, never from a disk video.
    public sealed class Preview : IDisposable {
        readonly Process process;
        readonly Task input, frames;
        readonly Task<string> errors;
        byte[] latest;
        volatile bool stopping;
        public bool Done { get { return input.IsCompleted && frames.IsCompleted; } }
        public string Error {
            get {
                if (stopping) return null;
                if (input.IsFaulted) return input.Exception.GetBaseException().Message;
                if (frames.IsFaulted) return frames.Exception.GetBaseException().Message;
                if (Done && process.HasExited && process.ExitCode != 0) return "视频解码失败: " + (errors.IsCompleted ? errors.Result : "");
                return null;
            }
        }
        public Preview(string recording, string key, string password, string ffmpeg) {
            process = new Process();
            process.StartInfo = new ProcessStartInfo(ffmpeg, "-hide_banner -loglevel error -re -i pipe:0 -an -vf scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2,fps=5 -pix_fmt bgra -f rawvideo pipe:1") {
                UseShellExecute=false, CreateNoWindow=true, RedirectStandardInput=true, RedirectStandardOutput=true, RedirectStandardError=true
            };
            process.Start(); errors=process.StandardError.ReadToEndAsync();
            input=Task.Run(() => {
                try { Vault.Decrypt(recording,key,password,process.StandardInput.BaseStream); }
                catch { if (!stopping && !process.HasExited) process.Kill(); if (!stopping) throw; }
                finally { try { process.StandardInput.Close(); } catch { } }
            });
            frames=Task.Run(() => {
                try {
                    while (!stopping) {
                        byte[] buffer=new byte[640*360*4]; int offset=0;
                        while(offset < buffer.Length) {
                            int n=process.StandardOutput.BaseStream.Read(buffer,offset,buffer.Length-offset);
                            if(n==0) { if(offset != 0 && !stopping) throw new InvalidDataException("Incomplete video frame"); return; }
                            offset+=n;
                        }
                        Interlocked.Exchange(ref latest,buffer);
                    }
                } catch { if(!stopping) throw; }
            });
        }
        public byte[] TakeFrame() { return Interlocked.Exchange(ref latest,null); }
        public void Dispose() {
            stopping=true;
            if(!process.HasExited) process.Kill();
            try { Task.WaitAll(new Task[]{input,frames},3000); } catch { }
            // Input authentication may still be finishing; dispose once both workers have unwound.
            if(Done) process.Dispose();
            else Task.WhenAll(input,frames).ContinueWith(_ => process.Dispose());
            latest=null;
        }
    }
}
