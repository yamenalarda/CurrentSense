"""Numerical prototype of the AC detection chain (NOT the shipped Swift code).
Purpose: sanity-check thresholds/expectations used in the Swift tests before a macOS runner is available.
"""
import math, random

def lp_update(state, x, dt, tau):
    if state is None: return x
    a = 1 - math.exp(-dt / tau)
    return state + (x - state) * a

class HP2:
    def __init__(s, fc): s.tau = 1/(2*math.pi*fc); s.l1=None; s.l2=None; s.t=None
    def upd(s, x, t):
        dt = 0 if s.t is None else t - s.t; s.t = t
        s.l1 = lp_update(s.l1, x, dt, s.tau); y1 = x - s.l1
        s.l2 = lp_update(s.l2, y1, dt, s.tau); return y1 - s.l2

def run(tone_f=None, amp=0, phase=0.0, fs=100.0, noise=0.1, seed=1, quiet=2.0, active=4.0, axis=0):
    rnd = random.Random(seed)
    hps = [HP2(min(8.0, fs*0.1)) for _ in range(3)]
    n_q = int(quiet*fs); n_a = int(active*fs)
    floor_sq = 0; cnt = 0
    for i in range(n_q):
        t = i/fs
        y = [hp.upd(rnd.gauss(0, noise), t) for hp in hps]
        if t >= 0.3: floor_sq += sum(v*v for v in y); cnt += 1
    floor = math.sqrt(floor_sq/cnt)
    win = []; res = []
    for i in range(n_a):
        t = quiet + i/fs
        x = [rnd.gauss(0, noise) for _ in range(3)]
        if tone_f: x[axis] += amp*math.sin(2*math.pi*tone_f*t + phase)
        y = [hp.upd(v, t) for hp, v in zip(hps, x)]
        win.append(sum(v*v for v in y)); win = win[-int(fs):]
        if i > fs: res.append(math.sqrt(sum(win)/len(win))/floor)
    return floor, res[-1], min(res), max(res)

for name, kw in [("noise only", {}), ("60 Hz amp 2", dict(tone_f=60, amp=2)), ("60 Hz amp 8", dict(tone_f=60, amp=8)),
                 ("60 Hz amp 0.2", dict(tone_f=60, amp=0.2)), ("60 Hz amp 0.7", dict(tone_f=60, amp=0.7)),
                 ("50 Hz amp 2 phase pi/2 (Nyquist)", dict(tone_f=50, amp=2, phase=math.pi/2)),
                 ("50 Hz amp 2 phase 0 (Nyquist blind)", dict(tone_f=50, amp=2, phase=0)),
                 ("1.5 Hz sway amp 5", dict(tone_f=1.5, amp=5)), ("130 Hz amp 2", dict(tone_f=130, amp=2))]:
    f, last, lo, hi = run(**kw)
    print(f"{name:40s} floor={f:.3f} uT  ratio last={last:5.2f} min={lo:5.2f} max={hi:5.2f}")

# false-alarm sweep: 200 seeds of noise only, max ratio over 20 s
worst = 0
for sd in range(200):
    f, last, lo, hi = run(seed=sd, active=20)
    worst = max(worst, hi)
print("noise-only worst-case ratio over 200 seeds x 20 s:", round(worst, 2), "(enter threshold = 2.0)")

# ---- mains-tone fraction check (single-frequency projection on real timestamps) ----
def narrow(times, vals, f):
    n=len(vals); w=2*math.pi*f; t0=times[0]; c=s=p=0.0
    for t,v in zip(times,vals):
        ph=w*(t-t0); c+=v*math.cos(ph); s+=v*math.sin(ph); p+=v*v
    return 2*(c*c+s*s)/(n*n), p/n

def fraction(times, axes, alias, scan=1.0, step=0.25):
    best=0; df=-scan
    while df<=scan+1e-9:
        f=alias+df
        if f>0:
            parts=[narrow(times,a,f) for a in axes]
            tot=sum(p[1] for p in parts)
            if tot>0: best=max(best, sum(p[0] for p in parts)/tot)
        df+=step
    return best

def mains_case(f_src, amp, seed=3, fs=100.0, jitter=0.0):
    rnd=random.Random(seed); hps=[HP2(8.0) for _ in range(3)]
    ts=[]; ax=[[],[],[]]
    for i in range(int(3*fs)):
        t=i/fs + (rnd.uniform(-jitter,jitter)/fs if jitter else 0)
        x=[rnd.gauss(0,0.1) for _ in range(3)]; x[0]+=amp*math.sin(2*math.pi*f_src*t)
        y=[hp.upd(v,t) for hp,v in zip(hps,x)]
        if i>=2*fs: ts.append(t); [a.append(v) for a,v in zip(ax,y)]
    return fraction(ts,ax,40.0)   # alias of 60 Hz at fs=100

print("\nfraction at 40 Hz alias (threshold 0.35):")
for name,args in [("60 Hz tone",(60,1.5)),("60 Hz tone, jitter 0.2",(60,1.5,3,100.0,0.2)),("130 Hz (alias 30 Hz)",(130,1.5)),("noise only",(60,0.0)),("0.35 uT 60 Hz",(60,0.35))]:
    print(f"  {name:28s} {mains_case(*args):.3f}")
