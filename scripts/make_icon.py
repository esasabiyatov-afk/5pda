import sys, math
from PIL import Image, ImageDraw, ImageFont, ImageFilter
K=4; S=1024*K
def lerp(a,b,t): return tuple(int(a[i]+(b[i]-a[i])*t) for i in range(3))
# diagonal gradient background
c1=(41,121,255); c2=(98,54,214)
g=Image.new("RGB",(256,256)); px=g.load()
for y in range(256):
    for x in range(256):
        px[x,y]=lerp(c1,c2,(x+y)/510)
bg=g.resize((S,S),Image.BICUBIC).convert("RGBA")
# soft glow top-left
glow=Image.new("L",(S,S),0); ImageDraw.Draw(glow).ellipse([-S*0.3,-S*0.4,S*0.8,S*0.6],fill=45)
glow=glow.filter(ImageFilter.GaussianBlur(S*0.18))
bg=Image.composite(Image.new("RGBA",(S,S),(255,255,255,255)),bg,glow)
# bubble shadow
sh=Image.new("L",(S,S),0); sd=ImageDraw.Draw(sh)
bx0,by0,bx1,by1=int(S*.19),int(S*.2),int(S*.81),int(S*.72); r=int(S*.15)
def bubble(d,off,fill):
    d.rounded_rectangle([bx0,by0+off,bx1,by1+off],radius=r,fill=fill)
    d.polygon([(int(S*.30),by1-r//2+off),(int(S*.27),int(S*.84)+off),(int(S*.47),by1+off-2)],fill=fill)
bubble(sd,int(S*.025),110)
sh=sh.filter(ImageFilter.GaussianBlur(S*.025))
bg=Image.composite(Image.new("RGBA",(S,S),(20,10,70,255)),bg,sh)
# bubble
m=Image.new("L",(S,S),0); bubble(ImageDraw.Draw(m),0,255)
bg=Image.composite(Image.new("RGBA",(S,S),(255,255,255,255)),bg,m)
# gradient "5"
f=ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", int(S*.46))
tm=Image.new("L",(S,S),0); td=ImageDraw.Draw(tm)
bb=td.textbbox((0,0),"5",font=f); w=bb[2]-bb[0]; h=bb[3]-bb[1]
cx=(bx0+bx1)/2; cy=(by0+by1)/2
td.text((cx-w/2-bb[0], cy-h/2-bb[1]),"5",font=f,fill=255)
grad=g.resize((S,S),Image.BICUBIC).convert("RGBA")
bg=Image.composite(grad,bg,tm)
bg.resize((1024,1024),Image.LANCZOS).convert("RGB").save(sys.argv[1])
