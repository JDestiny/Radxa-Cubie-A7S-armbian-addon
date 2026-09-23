// SPDX-License-Identifier: GPL-2.0
/*
 * tz2hwmon v2 — thermal_zone → hwmon 只读桥接模块 (sensors / btop / htop 可见)
 *
 * 背景: 全志 BSP 的温度只注册在 thermal_zone (cpub/cpul/ddr/npu/gpu/skin...),
 *       未桥接成 hwmon, 而 libsensors 只认 hwmon → sensors / btop / htop 都读不到。
 *
 * v2 (2026-09-12) 关键改动 —— 让 htop 真正显示温度:
 *   htop 3.x 通过 dlopen("libsensors.so.5") 读 hwmon, 但**只接受白名单芯片名**
 *   (二进制内置: cpu_thermal / soc_thermal / acpitz / coretemp / k10temp / zenpower)。
 *   v1 统一命名 tz2hwmonN → htop 直接忽略(表头永远空白)。v2 改为:
 *     cpub_thermal_zone → chip "cpu_thermal"  (命中 htop 白名单 → 显示 CPU 温度)
 *     cpul_thermal_zone → chip "soc_thermal"  (命中 htop 白名单)
 *     ddr/npu/gpu/skin  → chip "<x>_thermal"  (sensors / btop 可读)
 *     *_idle_zone       → 默认**跳过**(与主 zone 同源, 避免重复计数; include_aliases=1 保留)
 *   每个通道另给 temp1_label (cpub/cpul/ddr/npu/gpu/skin), sensors 输出更直观。
 *
 * 特性: 纯只读、纯展示; 不注册 thermal governor 回调, 不影响内核温控与 trip 点。
 *
 * 编译:  make -C /lib/modules/$(uname -r)/build M=$PWD modules
 * 安装:  sudo ./install-tz2hwmon.sh      (推荐: 编译/安装/自启/校验/卸载一体)
 * 手动:  sudo insmod tz2hwmon.ko [include_aliases=1]
 *        sudo cp tz2hwmon.ko /lib/modules/$(uname -r)/extra/ && sudo depmod -a
 *        echo tz2hwmon | sudo tee /etc/modules-load.d/tz2hwmon.conf
 * 卸载:  sudo rmmod tz2hwmon
 */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/hwmon.h>
#include <linux/fs.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/device.h>
#include <linux/kstrtox.h>

#define TZ_MAX		16
#define NAME_LEN	32
#define TYPE_LEN	48

static bool include_aliases;
module_param(include_aliases, bool, 0444);
MODULE_PARM_DESC(include_aliases,
		 "include *_idle_zone aliases as separate chips (default: off)");

struct tz_entry {
	char zone[NAME_LEN];		/* thermal_zoneN */
	char type[TYPE_LEN];		/* cpub_thermal_zone ... */
	char chipname[NAME_LEN];	/* hwmon chip 名 (尽量命中 htop 白名单) */
	char label[NAME_LEN];		/* temp1_label */
	struct device *hwdev;
	struct attribute_group group;
	struct attribute *attrs[3];
	struct device_attribute da;	/* temp1_input */
	struct device_attribute la;	/* temp1_label */
	const struct attribute_group *groups[2];
};

static struct tz_entry *tz_list;
static int tz_count;

/* 读 /sys/class/thermal/<zone>/<attr> 文本, 返回长度; 失败返回负值 */
static int tz_read_str(const char *zone, const char *attr, char *buf, size_t len)
{
	char path[128];
	struct file *f;
	loff_t pos = 0;
	int n;

	snprintf(path, sizeof(path), "/sys/class/thermal/%s/%s", zone, attr);
	f = filp_open(path, O_RDONLY, 0);
	if (IS_ERR(f))
		return -ENODATA;

	n = kernel_read(f, buf, len - 1, &pos);
	filp_close(f, NULL);
	if (n <= 0)
		return -ENODATA;
	buf[n] = '\0';
	strim(buf);
	return n;
}

/* 读温度 (m°C), 失败返回负值 */
static long tz_read_temp(const char *zone)
{
	char buf[32];
	long temp = -ENODATA;

	if (tz_read_str(zone, "temp", buf, sizeof(buf)) < 0)
		return -ENODATA;
	if (kstrtol(buf, 10, &temp))
		return -ENODATA;
	return temp;
}

static ssize_t temp1_show(struct device *dev, struct device_attribute *attr,
			  char *buf)
{
	struct tz_entry *e = container_of(attr, struct tz_entry, da);
	long t = tz_read_temp(e->zone);

	if (t < 0)
		return -ENODATA;
	return sysfs_emit(buf, "%ld\n", t);
}

static ssize_t label_show(struct device *dev, struct device_attribute *attr,
			  char *buf)
{
	struct tz_entry *e = container_of(attr, struct tz_entry, la);

	return sysfs_emit(buf, "%s\n", e->label);
}

/* 依据 zone type 决定 hwmon 芯片名与 label (芯片名尽量命中 htop 白名单) */
static void tz_pick_names(struct tz_entry *e)
{
	const char *t = e->type;
	char *p;

	/* label = type 去掉 _thermal_zone / _zone 后缀: cpub / cpul / gpu / skin ... */
	snprintf(e->label, sizeof(e->label), "%s", t);
	p = strstr(e->label, "_thermal_zone");
	if (p)
		*p = '\0';
	else if ((p = strstr(e->label, "_zone")))
		*p = '\0';

	if (strstr(t, "cpub"))
		snprintf(e->chipname, sizeof(e->chipname), "cpu_thermal");
	else if (strstr(t, "cpul"))
		snprintf(e->chipname, sizeof(e->chipname), "soc_thermal");
	else if (strstr(t, "gpu"))
		snprintf(e->chipname, sizeof(e->chipname), "gpu_thermal");
	else if (strstr(t, "npu"))
		snprintf(e->chipname, sizeof(e->chipname), "npu_thermal");
	else if (strstr(t, "ddr"))
		snprintf(e->chipname, sizeof(e->chipname), "ddr_thermal");
	else if (strstr(t, "skin"))
		snprintf(e->chipname, sizeof(e->chipname), "skin_thermal");
	else
		snprintf(e->chipname, sizeof(e->chipname), "tz2hwmon_%s", e->label);
}

static int tz_register(struct tz_entry *e)
{
	sysfs_attr_init(&e->da.attr);
	e->da.attr.name = "temp1_input";
	e->da.attr.mode = 0444;
	e->da.show = temp1_show;

	sysfs_attr_init(&e->la.attr);
	e->la.attr.name = "temp1_label";
	e->la.attr.mode = 0444;
	e->la.show = label_show;

	e->attrs[0] = &e->da.attr;
	e->attrs[1] = &e->la.attr;
	e->attrs[2] = NULL;
	e->group.attrs = e->attrs;
	e->groups[0] = &e->group;
	e->groups[1] = NULL;

	e->hwdev = hwmon_device_register_with_groups(NULL, e->chipname, e,
						     e->groups);
	if (IS_ERR(e->hwdev)) {
		pr_err("tz2hwmon: register %s (%s) failed %ld\n", e->zone,
		       e->chipname, PTR_ERR(e->hwdev));
		e->hwdev = NULL;
		return -1;
	}
	pr_debug("tz2hwmon: %s [%s] -> hwmon \"%s\" label \"%s\"\n", e->zone,
		 e->type, e->chipname, e->label);
	return 0;
}

static int __init tz2hwmon_init(void)
{
	char path[96], buf[TYPE_LEN];
	int n, nreg = 0, nskip = 0;

	/* 探测 thermal_zone0..N 个数 */
	for (n = 0; n < TZ_MAX; n++) {
		struct file *f;

		snprintf(path, sizeof(path),
			 "/sys/class/thermal/thermal_zone%d/temp", n);
		f = filp_open(path, O_RDONLY, 0);
		if (IS_ERR(f))
			break;
		filp_close(f, NULL);
	}
	pr_debug("tz2hwmon: found %d thermal zones (include_aliases=%d)\n", n,
		 include_aliases);
	if (n == 0)
		return -ENODEV;

	tz_list = kcalloc(n, sizeof(*tz_list), GFP_KERNEL);
	if (!tz_list)
		return -ENOMEM;

	for (n = 0; n < TZ_MAX; n++) {
		struct tz_entry *e = &tz_list[nreg];

		snprintf(e->zone, sizeof(e->zone), "thermal_zone%d", n);
		if (tz_read_str(e->zone, "type", buf, sizeof(buf)) < 0)
			break;			/* 没有更多 zone 了 */
		snprintf(e->type, sizeof(e->type), "%s", buf);

		/* 同源别名默认跳过 (cpul_idle_zone / cpub_idle_zone 等) */
		if (!include_aliases && strstr(e->type, "_idle_zone")) {
			pr_debug("tz2hwmon: skip alias %s (%s)\n", e->zone,
				 e->type);
			nskip++;
			continue;
		}

		tz_pick_names(e);
		if (tz_register(e) == 0)
			nreg++;
	}

	pr_info("tz2hwmon: %d channels registered, %d alias(es) skipped\n",
		nreg, nskip);	/* 仅加载时一行 */
	tz_count = nreg;
	return nreg ? 0 : -ENODEV;
}

static void __exit tz2hwmon_exit(void)
{
	int n;

	for (n = 0; n < tz_count; n++)
		if (tz_list[n].hwdev)
			hwmon_device_unregister(tz_list[n].hwdev);
	kfree(tz_list);
	tz_list = NULL;
	tz_count = 0;
	pr_debug("tz2hwmon: unloaded\n");
}

module_init(tz2hwmon_init);
module_exit(tz2hwmon_exit);

MODULE_DESCRIPTION("thermal_zone to hwmon bridge (read-only; htop-compatible chip names)");
MODULE_AUTHOR("Cubie A7S Armbian port");
MODULE_LICENSE("GPL v2");
MODULE_VERSION("2.0");
