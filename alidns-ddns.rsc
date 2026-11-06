# alidns-ddns: keep A/AAAA records in Alibaba Cloud DNS current from RouterOS
#
# Configure the globals in the block immediately below this header
# (alidnsAKID, alidnsAKSEC, alidnsRR, alidnsRID*, alidnsIFC, alidnsDomain).
# Everything after that block is generic and needs no changes.
#
# Usage:  /import file=alidns-ddns.rsc
# Recurring use:
#   /system scheduler add name=alidns-ddns start-time=startup interval=5m \
#       on-event="/import file=alidns-ddns.rsc"
# Requires RouterOS 7.16+ (:convert byte-array / base64 support).
# The script logs "alidns: <name> <type> unchanged <value>" or
# "alidns: <name> <type> -> <value>" per record; check with
#   /log print where message~"alidns"
:global alidnsAKID "YOUR_ACCESS_KEY_ID"
:global alidnsAKSEC "YOUR_ACCESS_KEY_SECRET"
:global alidnsRR "home"
:global alidnsRID6 "YOUR_RECORD_ID_AAAA"
:global alidnsRID6V "YOUR_RECORD_ID_AAAA_V6"
:global alidnsRID4 "YOUR_RECORD_ID_A"
:global alidnsRID4V "YOUR_RECORD_ID_A_V4"
:global alidnsIFC "bridge1"
:global alidnsDomain "example.com"
:global sha1raw do={
    :local msg $1
    :local n [:len $msg]
    :local m [:toarray ""]
    :if ($n > 0) do={ :for i from=0 to=($n - 1) do={ :set ($m->$i) ($msg->$i) } }
    :set ($m->$n) 128
    :local pad ($n + 1)
    :while (($pad % 64) != 56) do={ :set ($m->$pad) 0; :set pad ($pad + 1) }
    :local bl ($n * 8)
    :set ($m->$pad) 0
    :set ($m->($pad + 1)) 0
    :set ($m->($pad + 2)) 0
    :set ($m->($pad + 3)) 0
    :set ($m->($pad + 4)) (($bl >> 24) & 255)
    :set ($m->($pad + 5)) (($bl >> 16) & 255)
    :set ($m->($pad + 6)) (($bl >> 8) & 255)
    :set ($m->($pad + 7)) ($bl & 255)
    :local h0 0x67452301
    :local h1 0xEFCDAB89
    :local h2 0x98BADCFE
    :local h3 0x10325476
    :local h4 0xC3D2E1F0
    :local blocks (($pad + 8) / 64)
    :for blk from=0 to=($blocks - 1) do={
        :local W [:toarray ""]
        :for i from=0 to=15 do={
            :local o (($blk * 64) + ($i * 4))
            :set ($W->$i) (((($m->$o) << 24) | (($m->($o + 1)) << 16) | (($m->($o + 2)) << 8) | ($m->($o + 3))) & 0xFFFFFFFF)
        }
        :for i from=16 to=79 do={
            :local x (($W->($i - 3)) ^ ($W->($i - 8)) ^ ($W->($i - 14)) ^ ($W->($i - 16)))
            :set ($W->$i) (((($x << 1) | ($x >> 31))) & 0xFFFFFFFF)
        }
        :local a $h0
        :local b $h1
        :local c $h2
        :local d $h3
        :local e $h4
        :for i from=0 to=19 do={
            :local f ((($b & $c) | (($b ^ 0xFFFFFFFF) & $d)))
            :local rr (((($a << 5) | ($a >> 27)) & 0xFFFFFFFF))
            :local t ((($rr + $f + $e + 0x5A827999 + ($W->$i)) & 0xFFFFFFFF))
            :set e $d
            :set d $c
            :set c (((($b << 30) | ($b >> 2)) & 0xFFFFFFFF))
            :set b $a
            :set a $t
        }
        :for i from=20 to=39 do={
            :local f ($b ^ $c ^ $d)
            :local rr (((($a << 5) | ($a >> 27)) & 0xFFFFFFFF))
            :local t ((($rr + $f + $e + 0x6ED9EBA1 + ($W->$i)) & 0xFFFFFFFF))
            :set e $d
            :set d $c
            :set c (((($b << 30) | ($b >> 2)) & 0xFFFFFFFF))
            :set b $a
            :set a $t
        }
        :for i from=40 to=59 do={
            :local f ((($b & $c) | ($b & $d) | ($c & $d)))
            :local rr (((($a << 5) | ($a >> 27)) & 0xFFFFFFFF))
            :local t ((($rr + $f + $e + 0x8F1BBCDC + ($W->$i)) & 0xFFFFFFFF))
            :set e $d
            :set d $c
            :set c (((($b << 30) | ($b >> 2)) & 0xFFFFFFFF))
            :set b $a
            :set a $t
        }
        :for i from=60 to=79 do={
            :local f ($b ^ $c ^ $d)
            :local rr (((($a << 5) | ($a >> 27)) & 0xFFFFFFFF))
            :local t ((($rr + $f + $e + 0xCA62C1D6 + ($W->$i)) & 0xFFFFFFFF))
            :set e $d
            :set d $c
            :set c (((($b << 30) | ($b >> 2)) & 0xFFFFFFFF))
            :set b $a
            :set a $t
        }
        :set h0 ((($h0 + $a)) & 0xFFFFFFFF)
        :set h1 ((($h1 + $b)) & 0xFFFFFFFF)
        :set h2 ((($h2 + $c)) & 0xFFFFFFFF)
        :set h3 ((($h3 + $d)) & 0xFFFFFFFF)
        :set h4 ((($h4 + $e)) & 0xFFFFFFFF)
    }
    :local out [:toarray ""]
    :local hs {$h0; $h1; $h2; $h3; $h4}
    :for j from=0 to=4 do={
        :local v ($hs->$j)
        :set ($out->(($j * 4) + 0)) (($v >> 24) & 255)
        :set ($out->(($j * 4) + 1)) (($v >> 16) & 255)
        :set ($out->(($j * 4) + 2)) (($v >> 8) & 255)
        :set ($out->(($j * 4) + 3)) ($v & 255)
    }
    :return $out
}
:global hmacb64 do={
    :global sha1raw
    :local key $1
    :local msg $2
    :if ([:len $key] > 64) do={ :set key [$sha1raw $key] }
    :local kp [:toarray ""]
    :for i from=0 to=63 do={
        :if ($i < [:len $key]) do={ :set ($kp->$i) ($key->$i) } else={ :set ($kp->$i) 0 }
    }
    :local ip [:toarray ""]
    :local op [:toarray ""]
    :for i from=0 to=63 do={
        :set ($ip->$i) (($kp->$i) ^ 0x36)
        :set ($op->$i) (($kp->$i) ^ 0x5C)
    }
    :local inner [:toarray ""]
    :for i from=0 to=63 do={ :set ($inner->$i) ($ip->$i) }
    :for i from=0 to=( [:len $msg] - 1) do={ :set ($inner->(64 + $i)) ($msg->$i) }
    :local ih [$sha1raw $inner]
    :local outer [:toarray ""]
    :for i from=0 to=63 do={ :set ($outer->$i) ($op->$i) }
    :for i from=0 to=19 do={ :set ($outer->(64 + $i)) ($ih->$i) }
    :local oh [$sha1raw $outer]
    :return [:convert from=byte-array to=base64 value=$oh]
}
:global urlenc do={
    :local s [:tostr $1]
    :local out ""
    :local ht "0123456789ABCDEF"
    :local ok "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    :if ([:len $s] > 0) do={
        :for i from=0 to=( [:len $s] - 1) do={
            :local c [:pick $s $i ($i + 1)]
            :if ([:find $ok $c] >= 0) do={
                :set out ($out . $c)
            } else={
                :local by ([:convert to=byte-array value=$c]->0)
                :set out ($out . "%" . [:pick $ht (($by >> 4) & 15) ((($by >> 4) & 15) + 1)] . [:pick $ht ($by & 15) (($by & 15) + 1)])
            }
        }
    }
    :return $out
}

:global utcstamp do={
    :local off [/system clock get gmt-offset]
    :local sec ([:tonum [:totime ([/system clock get date] . " " . [/system clock get time])]] - $off)
    :local days ($sec / 86400)
    :local sod ($sec % 86400)
    :local z ($days + 719468)
    :local era ($z / 146097)
    :local doe ($z - ($era * 146097))
    :local yoe (($doe - ($doe / 1460) + ($doe / 36524) - ($doe / 146096)) / 365)
    :local y ($yoe + ($era * 400))
    :local doy ($doe - ((365 * $yoe) + ($yoe / 4) - ($yoe / 100)))
    :local mp (((5 * $doy) + 2) / 153)
    :local d (($doy - (((153 * $mp) + 2) / 5)) + 1)
    :local m ($mp + 3)
    :if ($mp >= 10) do={ :set m ($mp - 9); :set y ($y + 1) }
    :local hh ($sod / 3600)
    :local mm (($sod % 3600) / 60)
    :local ss ($sod % 60)
    :local f do={ :local v $1; :if ($v < 10) do={ :return ("0" . $v) }; :return [:tostr $v] }
    :return ([:tostr $y] . "-" . [$f $m] . "-" . [$f $d] . "T" . [$f $hh] . ":" . [$f $mm] . ":" . [$f $ss] . "Z")
}

# Build the signed URL. Args: akId akSecret rr rtype value recordId [tstamp] [nonce]
:global alidnsUrl do={
    :global urlenc
    :global hmacb64
    :global alidnsDomain
    :local akid $1
    :local aksec $2
    :local rr $3
    :local rtype $4
    :local value $5
    :local rid $6
    :local ts $7
    :local nn $8
    :if ([:typeof $ts] = "nothing") do={ :global utcstamp; :set ts [$utcstamp] }
    :if ([:typeof $nn] = "nothing") do={
        :global alidnsNonce
        :if ([:typeof $alidnsNonce] = "nothing") do={ :set alidnsNonce 0 }
        :set alidnsNonce ($alidnsNonce + 1)
        :set nn ([:tostr [:tonum [/system clock get time]]] . "-" . [:tostr $alidnsNonce])
    }
    :local c ("AccessKeyId=" . [$urlenc $akid] . "&Action=UpdateDomainRecord&Format=JSON&RR=" . [$urlenc $rr] . "&RecordId=" . [$urlenc $rid] . "&SignatureMethod=HMAC-SHA1&SignatureNonce=" . [$urlenc $nn] . "&SignatureVersion=1.0&Timestamp=" . [$urlenc $ts] . "&Type=" . [$urlenc $rtype] . "&Value=" . [$urlenc $value] . "&Version=2015-01-09")
    :local sts ("GET&%2F&" . [$urlenc $c])
    :local sig [$hmacb64 [:convert to=byte-array value=($aksec . "&")] [:convert to=byte-array value=$sts]]
    :return ("https://alidns.aliyuncs.com/?Signature=" . [$urlenc $sig] . "&" . $c)
}


:global alidnsDescUrl do={
    :global urlenc
    :global hmacb64
    :global alidnsDomain
    :local akid $1
    :local aksec $2
    :local rr $3
    :local rtype $4
    :local ts $5
    :local nn $6
    :if ([:typeof $ts] = "nothing") do={ :global utcstamp; :set ts [$utcstamp] }
    :if ([:typeof $nn] = "nothing") do={
        :global alidnsNonce
        :if ([:typeof $alidnsNonce] = "nothing") do={ :set alidnsNonce 0 }
        :set alidnsNonce ($alidnsNonce + 1)
        :set nn ([:tostr [:tonum [/system clock get time]]] . "-" . [:tostr $alidnsNonce])
    }
    :local c ("AccessKeyId=" . [$urlenc $akid] . "&Action=DescribeDomainRecords&DomainName=" . [$urlenc $alidnsDomain] . "&Format=JSON&PageSize=20&RRKeyWord=" . [$urlenc $rr] . "&SignatureMethod=HMAC-SHA1&SignatureNonce=" . [$urlenc $nn] . "&SignatureVersion=1.0&Timestamp=" . [$urlenc $ts] . "&Type=" . [$urlenc $rtype] . "&Version=2015-01-09")
    :local sts ("GET&%2F&" . [$urlenc $c])
    :local sig [$hmacb64 [:convert to=byte-array value=($aksec . "&")] [:convert to=byte-array value=$sts]]
    :return ("https://alidns.aliyuncs.com/?Signature=" . [$urlenc $sig] . "&" . $c)
}

:global alidnsRun do={
    :global urlenc
    :global utcstamp
    :global hmacb64
    :global alidnsUrl
    :global alidnsDescUrl
    :global alidnsAKID
    :global alidnsAKSEC
    :global alidnsRR
    :global alidnsRID6
    :global alidnsRID6V
    :global alidnsRID4
    :global alidnsRID4V
    :global alidnsIFC
    :local v6 ""
    :foreach id in=[/ipv6 address find where interface=$alidnsIFC] do={
        :local a [/ipv6 address get $id address]
        :if ([:pick $a 0 1] = "2") do={ :set v6 [:pick $a 0 [:find $a "/"]] }
    }
    :local v4 [:tostr [/ip cloud get public-address]]
    :local jobs [:toarray ""]
    :if ($v6 != "") do={
        :set ($jobs->0) ($alidnsRID6 . "," . "AAAA" . "," . $v6 . "," . $alidnsRR)
        :set ($jobs->1) ($alidnsRID6V . "," . "AAAA" . "," . $v6 . "," . $alidnsRR . ".v6")
    }
    :if (($v4 != "") and ($alidnsRID4 != "")) do={
        :set ($jobs->2) ($alidnsRID4 . "," . "A" . "," . $v4 . "," . $alidnsRR)
        :set ($jobs->3) ($alidnsRID4V . "," . "A" . "," . $v4 . "," . $alidnsRR . ".v4")
    }
    :local n [:len $jobs]
    :local i 0
    :while ($i < $n) do={
        :local j ($jobs->$i)
        :set i ($i + 1)
        :if ($j != "") do={
            :local rid  [:pick $j 0 [:find $j ","]]
            :local rest [:pick $j ([:find $j ","] + 1) [:len $j]]
            :local t    [:pick $rest 0 [:find $rest ","]]
            :local rest2 [:pick $rest ([:find $rest ","] + 1) [:len $rest]]
            :local val  [:pick $rest2 0 [:find $rest2 ","]]
            :local nm   [:pick $rest2 ([:find $rest2 ","] + 1) [:len $rest2]]
            :if (($rid != "") and ($val != "")) do={
                :local body ""
                :do { :local durl [$alidnsDescUrl $alidnsAKID $alidnsAKSEC $nm $t]; :local d [/tool fetch url=$durl output=user as-value]; :set body ($d->"data") } on-error={ :set body "" }
                :if ([:find $body $val] >= 0) do={
                    :log info ("alidns: " . $nm . " " . $t . " unchanged " . $val)
                } else={
                    :local u [$alidnsUrl $alidnsAKID $alidnsAKSEC $nm $t $val $rid]
                    :do {
                        :local r [/tool fetch url=$u output=user as-value]
                        :log info ("alidns: " . $nm . " " . $t . " -> " . $val)
                    } on-error={
                        :log warning ("alidns: " . $nm . " " . $t . " update failed for " . $val)
                    }
                }
            }
        }
    }
}
:global alidnsRun
$alidnsRun
