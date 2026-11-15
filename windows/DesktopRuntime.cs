using System;
using System.IO;
using System.Diagnostics;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;

namespace RemoteGuard {
    // Keep one authenticated compressed movie in RAM. No plaintext media file is created.
    public sealed class Preview : IDisposable {
        public const int Width=1920, Height=1080;
        readonly object gate=new object();
        readonly Task worker;
        Process process;
        byte[] latest;
        bool stopping, ready, paused, ended;
        int revision;
        double duration, position, requested, rate=1;
        string error;
        public bool Ready { get { lock(gate) return ready; } }
        public bool Done { get { lock(gate) return ended || worker.IsCompleted; } }
        public bool Paused { get { lock(gate) return paused; } }
        public double Duration { get { lock(gate) return duration; } }
        public double Position { get { lock(gate) return position; } }
        public double Rate { get { lock(gate) return rate; } }
        public string Error { get { lock(gate) return error; } }
        public Preview(string recording,string key,string password,string ffmpeg) {
            worker=Task.Run(() => Run(recording,key,password,ffmpeg));
        }
        void KillDecoder() { if(process != null) try { if(!process.HasExited) process.Kill(); } catch(InvalidOperationException) { } }
        public void Seek(double seconds) {
            if(Double.IsNaN(seconds) || Double.IsInfinity(seconds)) return;
            lock(gate) {
                if(!ready || stopping) return;
                requested=Math.Max(0,Math.Min(seconds,Math.Max(0,duration-0.2)));
                position=requested; ended=false; revision++; Interlocked.Exchange(ref latest,null);
                KillDecoder(); Monitor.PulseAll(gate);
            }
        }
        public void SetRate(double value) {
            if(Double.IsNaN(value) || value < 0.25 || value > 4) throw new ArgumentOutOfRangeException("value");
            lock(gate) { rate=value; Monitor.PulseAll(gate); }
        }
        public void SetPaused(bool value) {
            lock(gate) {
                if(ended && !value) { requested=0; position=0; ended=false; revision++; KillDecoder(); }
                paused=value; Monitor.PulseAll(gate);
            }
        }
        Process Start(string ffmpeg,string arguments) {
            lock(gate) {
                if(stopping) throw new OperationCanceledException();
                var value=new Process();
                value.StartInfo=new ProcessStartInfo(ffmpeg,arguments) { UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true };
                if(!value.Start()) { value.Dispose(); throw new IOException("无法启动视频解码器"); }
                process=value; return value;
            }
        }
        void Release(Process value) { lock(gate) { if(process == value) process=null; } value.Dispose(); }
        static Task Feed(Process value,MemoryStream movie) {
            return Task.Run(() => {
                try { value.StandardInput.BaseStream.Write(movie.GetBuffer(),0,(int)movie.Length); }
                catch(IOException) { } catch(ObjectDisposedException) { }
                finally { try { value.StandardInput.Close(); } catch { } }
            });
        }
        double Probe(string ffmpeg,MemoryStream movie) {
            var value=Start(ffmpeg,"-hide_banner -loglevel error -nostats -progress pipe:2 -threads 2 -i pipe:0 -map 0:v:0 -an -vf scale=2:2 -threads 2 -f null -");
            var input=Feed(value,movie); var errors=value.StandardError.ReadToEndAsync();
            try {
                if(!value.WaitForExit(30000)) { lock(gate) KillDecoder(); throw new IOException("读取录像时长超时"); }
                input.Wait(); string output=errors.Result;
                if(value.ExitCode != 0) throw new IOException("录像时长读取失败: "+output);
                double seconds=MediaProgress.Duration(output);
                if(seconds <= 0) throw new InvalidDataException("录像没有可播放的视频帧");
                return seconds;
            } finally { if(!value.HasExited) value.Kill(); input.Wait(); Release(value); }
        }
        void Run(string recording,string key,string password,string ffmpeg) {
            using(var movie=new MemoryStream()) {
                try {
                    if(new FileInfo(recording).Length > 256L*1024*1024) throw new InvalidDataException("录像片段超过 256 MB 播放上限");
                    using(var bounded=new BoundedMovie(movie)) Vault.Decrypt(recording,key,password,bounded);
                    lock(gate) if(stopping) return;
                    double length=Probe(ffmpeg,movie);
                    lock(gate) { duration=length; ready=true; }
                    while(true) {
                        int generation; double start;
                        lock(gate) {
                            while(ended && !stopping) Monitor.Wait(gate);
                            if(stopping) return; generation=revision; start=requested;
                        }
                        Decode(ffmpeg,movie,start,generation);
                    }
                } catch(Exception ex) { lock(gate) { if(!stopping) error=ex.Message; } }
                finally { Array.Clear(movie.GetBuffer(),0,(int)movie.Length); Interlocked.Exchange(ref latest,null); }
            }
        }
        void Decode(string ffmpeg,MemoryStream movie,double start,int generation) {
            // Output-side -ss discards up to the target on a pipe. No -re: skip promptly.
            var value=Start(ffmpeg,"-hide_banner -loglevel error -i pipe:0 -ss "+start.ToString("0.######",CultureInfo.InvariantCulture)+" -an -vf scale=w=min(1920\\,iw):h=min(1080\\,ih):force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=5 -threads 2 -pix_fmt bgra -f rawvideo pipe:1");
            var input=Feed(value,movie); var errors=value.StandardError.ReadToEndAsync(); int count=0;
            try {
                while(true) {
                    lock(gate) {
                        while(paused && count > 0 && !stopping && generation == revision) Monitor.Wait(gate);
                        if(stopping || generation != revision) return;
                    }
                    byte[] frame=new byte[Width*Height*4]; int offset=0;
                    while(offset < frame.Length) { int n=value.StandardOutput.BaseStream.Read(frame,offset,frame.Length-offset); if(n == 0) break; offset+=n; }
                    lock(gate) {
                        if(stopping || generation != revision) return;
                        if(offset == 0) break;
                        if(offset != frame.Length) throw new InvalidDataException("录像画面不完整");
                        position=Math.Min(duration,start+count/5.0); Interlocked.Exchange(ref latest,frame); count++;
                    }
                    var clock=Stopwatch.StartNew(); double elapsed=0;
                    lock(gate) {
                        while(elapsed < 0.2 && !stopping && generation == revision) {
                            double speed=rate; bool frozen=paused; clock.Restart(); Monitor.Wait(gate,20);
                            if(!frozen) elapsed+=clock.Elapsed.TotalSeconds*speed;
                        }
                    }
                }
                value.WaitForExit(); input.Wait();
                lock(gate) {
                    if(stopping || generation != revision) return;
                    if(value.ExitCode != 0) throw new IOException("视频解码失败: "+errors.Result);
                    position=duration; paused=true; ended=true;
                }
            } catch { lock(gate) { if(!stopping && generation == revision) throw; } }
            finally { lock(gate) { if(process == value) KillDecoder(); } input.Wait(); Release(value); }
        }
        public byte[] TakeFrame() { return Interlocked.Exchange(ref latest,null); }
        public void Dispose() { lock(gate) { stopping=true; KillDecoder(); Monitor.PulseAll(gate); } Interlocked.Exchange(ref latest,null); }
        sealed class BoundedMovie : Stream {
            readonly MemoryStream memory;
            public BoundedMovie(MemoryStream memory) { this.memory=memory; }
            public override void Write(byte[] b,int o,int c) { if(memory.Length+c > 256L*1024*1024) throw new InvalidDataException("录像片段超过播放内存上限"); memory.Write(b,o,c); }
            public override void Flush() { }
            public override bool CanRead { get { return false; } }
            public override bool CanSeek { get { return false; } }
            public override bool CanWrite { get { return true; } }
            public override long Length { get { return memory.Length; } }
            public override long Position { get { return memory.Position; } set { throw new NotSupportedException(); } }
            public override int Read(byte[] b,int o,int c) { throw new NotSupportedException(); }
            public override long Seek(long o,SeekOrigin s) { throw new NotSupportedException(); }
            public override void SetLength(long n) { throw new NotSupportedException(); }
        }
    }
}
