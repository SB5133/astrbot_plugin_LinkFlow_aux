#!/system/bin/sh
# CA bind mount 重挂(零 /system 写入), 由服务器 keepalive 经 adb 调用
CERTDIR=/data/local/tmp/cacerts
rm -rf $CERTDIR && mkdir -p $CERTDIR
cp /system/etc/security/cacerts/* $CERTDIR/
cp /data/local/tmp/c8750f0d.0 $CERTDIR/
chmod 644 $CERTDIR/*
chown root:root $CERTDIR/*
chcon u:object_r:system_security_cacerts_file:s0 $CERTDIR/* 2>/dev/null
mount -o bind $CERTDIR /system/etc/security/cacerts
echo REMOUNTED=$(ls /system/etc/security/cacerts/ | grep -c c8750f0d)
