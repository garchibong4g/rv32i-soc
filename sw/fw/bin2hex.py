import struct,sys
data=open(sys.argv[1],"rb").read()
while len(data)%4: data+=b'\x00'
words=struct.unpack("<%dI"%(len(data)//4), data)
open(sys.argv[2],"w").write("".join("%08x\n"%w for w in words))
