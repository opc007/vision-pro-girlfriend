"""pbxproj 自检：解析 OpenStep plist，校验结构与 UUID 引用完整性。

不依赖第三方库（沙箱里装不了），只做够用的校验：
1. 语法：花括号 / 圆括号配平，引号闭合
2. objects 里每个 UUID 只有一个定义
3. 所有被引用的 24 位十六进制 UUID 都有定义
4. section 注释成对
5. 关键 isa 节点齐全，target 的 fileSystemSynchronizedGroups 指向存在的 group
"""
import re
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "VisionProGirlfriend.xcodeproj/project.pbxproj"
src = open(PATH, encoding="utf-8").read()

errors = []

# ---------- 1. 注释 / 括号配平 ----------
depth_brace = depth_paren = 0
in_string = escape = False
for i, ch in enumerate(src):
    if in_string:
        if escape:
            escape = False
        elif ch == "\\":
            escape = True
        elif ch == '"':
            in_string = False
        continue
    if ch == '"':
        in_string = True
    elif ch == "{":
        depth_brace += 1
    elif ch == "}":
        depth_brace -= 1
    elif ch == "(":
        depth_paren += 1
    elif ch == ")":
        depth_paren -= 1
    if depth_brace < 0 or depth_paren < 0:
        errors.append(f"第 {i} 行附近括号提前闭合")
        break
if in_string:
    errors.append("有未闭合的字符串引号")
if depth_brace != 0:
    errors.append(f"花括号不配平，剩余 {depth_brace}")
if depth_paren != 0:
    errors.append(f"圆括号不配平，剩余 {depth_paren}")

begins = len(re.findall(r"/\* Begin (\w+) section \*/", src))
ends = len(re.findall(r"/\* End (\w+) section \*/", src))
if begins != ends:
    errors.append(f"section Begin({begins}) / End({ends}) 不成对")
opens = set(re.findall(r"/\* Begin (\w+) section \*/", src))
closes = set(re.findall(r"/\* End (\w+) section \*/", src))
if opens != closes:
    errors.append(f"section 名称不匹配：{opens ^ closes}")

# ---------- 2/3. UUID 定义与引用 ----------
UUID_RE = r"\b[0-9A-F]{24}\b"
defined = re.findall(r"^\t\t(" + UUID_RE + r")\s*(?:/\*.*?\*/)?\s*=", src, re.M)
dupes = {u for u in defined if defined.count(u) > 1}
if dupes:
    errors.append(f"UUID 重复定义：{sorted(dupes)}")

referenced = set(re.findall(UUID_RE, src))
missing = referenced - set(defined)
if missing:
    errors.append(f"引用了未定义的 UUID：{sorted(missing)}")

unreferenced = set(defined) - (referenced - set(defined))
orphan = set(defined) - referenced
if orphan:
    errors.append(f"定义了但没人引用（根对象除外）：{sorted(orphan)}")

# ---------- 4. 结构关键字 ----------
required = [
    "isa = PBXProject",
    "isa = PBXNativeTarget",
    "isa = PBXFileSystemSynchronizedRootGroup",
    'productType = "com.apple.product-type.application"',
    "rootObject =",
    "SDKROOT = xros;",
    "TARGETED_DEVICE_FAMILY = 7;",
    "SWIFT_VERSION = 5.0;",
    "CODE_SIGN_ENTITLEMENTS = VisionProGirlfriend/VisionProGirlfriend.entitlements;",
    "fileSystemSynchronizedGroups = (",
]
for token in required:
    if token not in src:
        errors.append(f"缺少必需配置：{token}")

target_count = len(re.findall(r"isa = PBXNativeTarget", src))
if target_count != 1:
    errors.append(f"期望 1 个 app target，实际 {target_count}")

build_cfg = len(re.findall(r"isa = XCBuildConfiguration", src))
if build_cfg != 4:
    errors.append(f"期望 4 个 build configuration（项目/目标 × Debug/Release），实际 {build_cfg}")

# ---------- 报告 ----------
print(f"对象数量：{len(defined)}")
print(f"section：{begins} 组")
if errors:
    print("\n❌ 校验不通过：")
    for e in errors:
        print("  -", e)
    sys.exit(1)
print("\n✅ pbxproj 结构校验通过")
