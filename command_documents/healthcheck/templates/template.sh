#!/bin/bash

# サマリ変数の初期化
SUMMARY=""

for arg in "$@"; do
    # 引数は1つを想定
    echo "----------"
    echo "引数: $arg"
    echo ""

    echo "$arg起動確認 / Check $arg active status"
    STATUS=$(systemctl is-active $arg)
    echo "$arg status: $STATUS"
    if [ "$STATUS" = "active" ]; then
        SUMMARY="OK"
    else
        SUMMARY="NG オフライン時間帯の影響も考慮に入れること / Please consider the impact of offline hours"
    fi

    echo "$arg起動確認 / Check $arg status"
    systemctl status $arg | head -20
    echo ""

    echo "$argプロセス確認 / Check $arg process"
    ps -ef | grep $arg | grep -v grep
    echo ""

done

# output to notes
echo "サマリ表示 / Display Summary"
if [ -n "$SUMMARY" ]; then
    echo "$arg status: $SUMMARY"
    echo ""
fi