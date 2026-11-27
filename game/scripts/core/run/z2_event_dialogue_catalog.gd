extends RefCounted

# S3-only verbatim fragments. Numeric/rule examples are intentionally omitted.
# Runtime binds source placeholders from actual quotes/facts; unknown branches stay empty.
const SOURCE_SHA256 := "515F69FF5463A87AA427B669C5D987CF959B652A726294864E4FEC1E808035A2"
const SOURCE_SHEET := "事件确认"
const SPEAKERS := {"information": "线报员", "shop": "店主", "savings": "储蓄机", "seal": "档案员", "mechanism": "机关", "recycle": "回收员", "relief": "老板", "first_aid": "播报", "consign": "接线员", "expand": "师傅", "compress": "屏幕", "trader": "旅商", "pawn": "放贷人", "shortcut": "检修工", "coil": "技师", "demine": "爆破手", "clock_in": "值班员", "recon": "侦察员", "rps": "闲客", "cage": "广播", "dice": "庄家", "altar": "祭坛"}
const FRAGMENTS := {
	"information.open": [{"text": "你是卖啥的？", "source_row": 13, "speaker": "玩家"}, {"text": "问那么难听干嘛，这叫提供情报！来，我可以免费给你一点点情报，你也可以稍微加点价，来搞点更加狠的价格！", "source_row": 13, "speaker": "线报员"}],
	"information.discount": [{"text": "哦？你以前也是这行的？同行都是朋友，这次给你便宜点！", "source_row": 14, "speaker": "线报员"}],
	"information.free": [{"text": "就这么点东西了，别把我话套完了。", "source_row": 16, "speaker": "线报员"}],
	"information.paid": [{"text": "感谢老板，老板大气！", "source_row": 20, "speaker": "线报员"}],
	"information.revisit": [{"text": "我这真没东西了，你去问问别人吧，别逮着我一个人薅了！", "source_row": 22, "speaker": "线报员"}],
	"shop.open": [{"text": "你这是地下商铺吗？", "source_row": 35, "speaker": "玩家"}, {"text": "包的！你别看这地下偏，我这的东西都是正品！童叟无欺如假包换！", "source_row": 35, "speaker": "店主"}, {"text": "看看有些啥？", "source_row": 35, "speaker": "玩家"}, {"text": "好嘞老板！自己挑！我这存货够，但你搬空了我可要收点跑腿费的哦！", "source_row": 35, "speaker": "店主"}],
	"shop.stock": [{"text": "上次的货还没人买呢，你看看当不当回头客？", "source_row": 39, "speaker": "店主"}],
	"shop.empty": [{"text": "这回真搬空啦？再添【本次刷新费用】枚跑腿费，我给你换一批！", "source_row": 39, "speaker": "店主"}],
	"shop.refresh": [{"text": "好嘞好嘞，新东西来咯，你看看合不合你口味？", "source_row": 38, "speaker": "店主"}],
	"savings.open": [{"text": "你是？", "source_row": 51, "speaker": "玩家"}, {"text": "窝…似…银行喵！翻…因…存款…喵！qnq", "source_row": 51, "speaker": "储蓄机"}, {"text": "？", "source_row": 51, "speaker": "玩家"}, {"text": "保证…不骗泥！Qwq泥…再碰到窝...可以…取出来的！", "source_row": 51, "speaker": "储蓄机"}],
	"savings.deposit": [{"text": "蟹蟹喵！蟹蟹喵！蟹蟹喵！蟹蟹喵！…", "source_row": 53, "speaker": "储蓄机"}, {"text": "（好像只会一直重复了）", "source_row": 53, "speaker": "玩家"}],
	"savings.thanks": [{"text": "蟹蟹喵！蟹蟹喵！蟹蟹喵！蟹蟹喵！…", "source_row": 53, "speaker": "储蓄机"}],
	"savings.same": [{"text": "（怎么还在重复...）", "source_row": 54, "speaker": "玩家"}],
	"savings.pending": [{"text": "啊！主银泥…上次存了【存款数】…药取出来喵？", "source_row": 54, "speaker": "储蓄机"}],
	"savings.withdraw": [{"text": "这储蓄机魔了。", "source_row": 54, "speaker": "玩家"}],
	"seal.open": [{"text": "你这是干嘛的？", "source_row": 66, "speaker": "玩家"}, {"text": "这里是封条柜，用于进行风险规避", "source_row": 66, "speaker": "档案员"}, {"text": "有什么要注意的？", "source_row": 66, "speaker": "玩家"}, {"text": "默认使用，您拿到后立即生效，不许耍赖，不许反悔。", "source_row": 66, "speaker": "档案员"}],
	"seal.discount": [{"text": "（档案员翻了翻登记簿。）", "source_row": 67}, {"text": "您以前登记过类似业务？您该走老客户路线", "source_row": 67, "speaker": "档案员"}],
	"seal.done": [{"text": "感谢您的到来，欢迎下次光临。", "source_row": 69, "speaker": "档案员"}, {"text": "（就这一张，他还是等我点了点头。）", "source_row": 69, "speaker": "玩家"}],
	"seal.revisit": [{"text": "您已申请过该业务。", "source_row": 70, "speaker": "档案员"}, {"text": "我想再——", "source_row": 70, "speaker": "玩家"}, {"text": "您已申请过该业务。", "source_row": 70, "speaker": "档案员"}, {"text": "就不能再通融下？", "source_row": 70, "speaker": "玩家"}, {"text": "您已申请过该业务。", "source_row": 70, "speaker": "档案员"}],
	"mechanism.electric": [{"text": "（柜门贴着“已断电，可安全操作”。拉手上跳过一道火花。）", "source_row": 82}, {"text": "叽里咕噜说什么呢，我来看看。", "source_row": 82, "speaker": "玩家"}],
	"mechanism.mechanical": [{"text": "（刻度停在【门槛】。告示上写着“请勿强行拆卸”，下面有人补了一句“否则打不开”。）", "source_row": 85}],
	"mechanism.electric_done": [{"text": "那张安全告示掉了下来。", "source_row": 84}],
	"mechanism.win": [{"text": "啊哈，就是这个！", "source_row": 87, "speaker": "玩家"}],
	"mechanism.loss": [{"text": "（拉杆猛地弹回，夹住了手指。）", "source_row": 88}, {"text": "嘶——", "source_row": 88, "speaker": "玩家"}],
	"mechanism.revisit": [{"text": "（隔层已经取空，或卡扣彻底咬死。装置没有新的反应。）", "source_row": 89}],
	"recycle.open": [{"text": "这东西怎么放在外面？", "source_row": 101, "speaker": "玩家"}, {"text": "垃圾堆里清出来的，你用得上就拿走，反正不用白不用了。", "source_row": 101, "speaker": "回收员"}, {"text": "真的实在确实一定用不上呢？", "source_row": 101, "speaker": "玩家"}, {"text": "（眼珠子转一下）那我可以勉强回收下，单独计价哦，你包里同类的也可以拿出来看看。", "source_row": 101, "speaker": "回收员"}],
	"recycle.take": [{"text": "好吧，那你自己拿稳咯，小心这垃圾边上有毛刺。", "source_row": 103, "speaker": "回收员"}],
	"recycle.deliver": [{"text": "（老人翻看了一下材料，在账本上记了一笔。）", "source_row": 104}, {"text": "好嘞！【报价】，记上了，剩下的路你自己小心！", "source_row": 104, "speaker": "回收员"}],
	"recycle.revisit": [{"text": "还没走远啊。你那一单结好了，放心。", "source_row": 105, "speaker": "回收员"}],
	"relief.open": [{"text": "（盆沿贴着一张泡得发白的纸，上面写着「请自行保管双脚」，老板把凳子推到你膝盖后面.）", "source_row": 117}, {"text": "坐坐坐，你这两条腿抖得都快把凳子晃热了，想泡脚还是松松筋骨？", "source_row": 117, "speaker": "老板"}, {"text": "我还有路要赶呢！", "source_row": 117, "speaker": "玩家"}, {"text": "知道，进来的都这么说，你先让腿歇着，嘴想赶路就让它赶.", "source_row": 117, "speaker": "老板"}],
	"relief.flat": [{"text": "（老板沿着管道摸到漏气的地方，垫上布片，把阀门拧了回去.尖响停了，他又贴近听了一会儿.）", "source_row": 119}, {"text": "这下清静了，你也不用跟着它一块儿绷着了.", "source_row": 119, "speaker": "老板"}],
	"relief.ten_percent": [{"text": "（热水没过脚背，你往凳子里面挪了挪，钱袋还抱在怀里.）", "source_row": 120}, {"text": "水温还行吧？烫了你就说，靴子我给你放旁边，起来时当心地滑.", "source_row": 120, "speaker": "老板"}],
	"relief.thirty_percent": [{"text": "是这儿难受？", "source_row": 121, "speaker": "老板"}, {"text": "哎哎哎轻点，疼！", "source_row": 121, "speaker": "玩家"}, {"text": "好好好，我换个地方.你手松一点，都快把凳子抠出印子了.", "source_row": 121, "speaker": "老板"}, {"text": "（老板放轻了手，顺着肩背慢慢按下去，你攥着凳沿的手也松开了.）", "source_row": 121}],
	"relief.revisit": [{"text": "怎么又转回来了，路不好走？你这回都做完了，坐会儿倒还行，凳子空着呢.", "source_row": 122, "speaker": "老板"}],
	"first_aid.normal": [{"text": "（屏幕坏了一角，笑脸只剩半张，报价还在下面滚动.）", "source_row": 134}, {"text": "欢迎使用自助急救柜", "source_row": 134, "speaker": "播报"}, {"text": "请按需取用.", "source_row": 134, "speaker": "播报"}],
	"first_aid.emergency": [{"text": "（红灯亮起，喇叭声突然盖过了你的说话声.）", "source_row": 135}, {"text": "已转入应急供应！", "source_row": 135, "speaker": "播报"}, {"text": "请保持冷静！", "source_row": 135, "speaker": "播报"}, {"text": "我听得见，你别这么大声啊！", "source_row": 135, "speaker": "玩家"}],
	"first_aid.done": [{"text": "（急救贴卡在出口晃了两下，机器里面又响了一声，才落进托盘.）", "source_row": 137}, {"text": "发放完成，请取走您的急救贴，祝您早日康复.", "source_row": 137, "speaker": "播报"}],
	"first_aid.revisit": [{"text": "（你又碰了碰领取键，屏幕上的笑脸还在闪，下面换了一行字.）", "source_row": 138}, {"text": "本柜物资已领取.", "source_row": 138, "speaker": "屏幕"}],
	"consign.open": [{"text": "单子写好，手别跟着伸进去！", "source_row": 150, "speaker": "接线员"}, {"text": "（管口贴着「人不可寄」，下面有人补了一行「装箱也不行」.）", "source_row": 150}, {"text": "你这管子真能送回仓库？", "source_row": 150, "speaker": "玩家"}, {"text": "能，你把名字写清楚，我们照单子送.", "source_row": 150, "speaker": "接线员"}],
	"consign.done": [{"text": "（包裹被吸走，管道里紧接着砰砰响了几声.）", "source_row": 152}, {"text": "喂轻点啊，里面装着东西呢！", "source_row": 152, "speaker": "玩家"}, {"text": "知道，是管子拐弯的动静！单子收到了，你这件给送回仓库.", "source_row": 152, "speaker": "接线员"}],
	"consign.revisit": [{"text": "你那件已经发走了，这个口子也封单了，别老伸手试！", "source_row": 153, "speaker": "接线员"}],
	"expand.open": [{"text": "（师傅扯开背包的裂缝，把顶在里面的东西往下压了压.）", "source_row": 165}, {"text": "都塞成这样了，你还打算往里装？", "source_row": 165, "speaker": "师傅"}, {"text": "装不下才来找你嘛，还能改不？", "source_row": 165, "speaker": "玩家"}, {"text": "要改就把包摘下来.", "source_row": 165, "speaker": "师傅"}],
	"expand.done": [{"text": "（师傅缝好肩带，让你背上试了试，又拉住扣子用力扯了两下.）", "source_row": 167}, {"text": "行了，这回能装下了，线头别乱剪啊.", "source_row": 167, "speaker": "师傅"}],
	"expand.revisit": [{"text": "这包我认得，刚在我这儿改过.同一个地方不能老这么加，你要还嫌小，往别处问问吧.", "source_row": 168, "speaker": "师傅"}],
	"compress.open": [{"text": "（进料口上贴着「请勿用手协助压实」，下面的小字已经磨掉一半，还能认出「协助者计入原料」.）", "source_row": 180}, {"text": "（清单翻到下一页，机器里面传来一声响.）", "source_row": 180}],
	"compress.done": [{"text": "（压板落下，出料口吐出【产物】，机器里面接着咳了一声.）", "source_row": 182}, {"text": "……里面有人吗？", "source_row": 182, "speaker": "玩家"}, {"text": "加工完成，请从出料口取物.", "source_row": 182, "speaker": "屏幕"}],
	"compress.revisit": [{"text": "（机器已经停了，进料口也合了起来，屏幕上留下本次加工的记录.）", "source_row": 183}, {"text": "本次加工已完成.", "source_row": 183, "speaker": "屏幕"}],
	"trader.open": [{"text": "背这么满，拿一件给我看看？吃的药的也收，留着用不上的不如换点钱.", "source_row": 196, "speaker": "旅商"}, {"text": "（他腾出桌边的一块地方，等你放东西.）", "source_row": 196}, {"text": "你肯出多少？", "source_row": 196, "speaker": "玩家"}, {"text": "那得看你拿什么呀，东西还在包里呢，我也看不见.", "source_row": 196, "speaker": "旅商"}],
	"trader.done": [{"text": "（旅商对完账，把收来的东西挪到脚边.）", "source_row": 201}, {"text": "好嘞，收到了！你也看看账，数对了就行.", "source_row": 201, "speaker": "旅商"}],
	"trader.revisit": [{"text": "你那单结过了，怎么又回来了？我这儿还没收拾开呢，等我把这些挪挪.", "source_row": 202, "speaker": "旅商"}],
	"pawn.open": [{"text": "（柜子里的押票码得整齐，放贷人把笔推到了你手边.）", "source_row": 214}, {"text": "人要是回不来了呢？", "source_row": 214, "speaker": "玩家"}, {"text": "您放心，东西放在我这里丢不了.", "source_row": 214, "speaker": "放贷人"}],
	"pawn.done": [{"text": "押票请收好", "source_row": 216, "speaker": "放贷人"}],
	"pawn.revisit": [{"text": "您的押品保管好了，这笔也已经办完，您还有事就去忙吧.", "source_row": 217, "speaker": "放贷人"}, {"text": "（他说完把柜门上的锁又转了一下.）", "source_row": 217}],
	"shortcut.open": [{"text": "要走哪边自己挑.", "source_row": 229, "speaker": "检修工"}, {"text": "我得知道通哪儿吧？", "source_row": 229, "speaker": "玩家"}, {"text": "开着的【可用口数】个都画在这儿了，你看看.", "source_row": 229, "speaker": "检修工"}],
	"shortcut.revisit": [{"text": "（检修工正在拧紧盖板，刚才亮着的灯已经灭了.）", "source_row": 232}, {"text": "走过了就别拽那个把手，我刚合上的.", "source_row": 232, "speaker": "检修工"}],
	"coil.open": [{"text": "包拿近一点，我刚把这儿调好，你试试……", "source_row": 244, "speaker": "技师"}, {"text": "（啪的一声，桌上的扳手吸了过去.）", "source_row": 244}, {"text": "哎哎扳手是我的！", "source_row": 244, "speaker": "技师"}, {"text": "这也算多找了一件？", "source_row": 244, "speaker": "玩家"}, {"text": "你别给我拿走啊，我昨天找了半天呢！", "source_row": 244, "speaker": "技师"}],
	"coil.calibrate": [{"text": "（技师把扳手塞进抽屉，重新合上开关，这回桌上的零件没再乱动.）", "source_row": 246}, {"text": "好了，你下次把普通房搜仔细点", "source_row": 246, "speaker": "技师"}],
	"coil.pending": [{"text": "灯还亮着呢，你还没用掉.找间普通房搜完整了，回来跟我说说多了个什么.", "source_row": 247, "speaker": "技师"}],
	"coil.revisit": [{"text": "多出来的是啥？跟我说说，我往本子上记一下.", "source_row": 248, "speaker": "技师"}, {"text": "（他翻了几页，在一行旧记录下面挤出一点空白.）", "source_row": 248}, {"text": "这台你用过了，我也没法给你再调一回，碰见另一台倒可以试试.", "source_row": 248, "speaker": "技师"}],
	"demine.open": [{"text": "正对着这间的邻房里，挑个插了旗的给我", "source_row": 260, "speaker": "爆破手"}, {"text": "万一没雷呢，钱能退吗？", "source_row": 260, "speaker": "玩家"}, {"text": "药都用了，退不了，你看准了再定.", "source_row": 260, "speaker": "爆破手"}],
	"demine.hit": [{"text": "（爆破手示意你捂住耳朵，按下起爆器，墙上的灰随着闷响落了一层.）", "source_row": 262}, {"text": "炸掉了，这颗我给你标上.", "source_row": 262, "speaker": "爆破手"}],
	"demine.miss": [{"text": "（隔壁只响了一声，爆破手听了听，低头开始卷线.）", "source_row": 263}, {"text": "没雷，你这旗插错了.", "source_row": 263, "speaker": "爆破手"}, {"text": "嗯，刚跟你说过了.", "source_row": 263, "speaker": "爆破手"}],
	"demine.revisit": [{"text": "我这儿那一发已经用掉了，下一面旗你拿图对一对，看准了再动手.", "source_row": 264, "speaker": "爆破手"}],
	"clock_in.open": [{"text": "要接活就在这儿签", "source_row": 276, "speaker": "值班员"}, {"text": "给你干活还得我掏钱？", "source_row": 276, "speaker": "玩家"}, {"text": "唉我来的时候也问过，没人理，后来就照着办了.", "source_row": 276, "speaker": "值班员"}, {"text": "（他把登记簿推过来，纸上还留着趴出来的折印.）", "source_row": 276}],
	"clock_in.register": [{"text": "（值班员盖上章，吹了吹没干的印泥，才把工单递过来.）", "source_row": 278}],
	"clock_in.progress": [{"text": "还差【剩余房间数】间，你看，这里没记上呢.", "source_row": 279, "speaker": "值班员"}, {"text": "（他指着空格，把工单还给你.）", "source_row": 279}],
	"clock_in.claim": [{"text": "数数吧，这单给你结了.", "source_row": 280, "speaker": "办事人"}],
	"clock_in.revisit": [{"text": "钱拿到了吧？那我把这张收起来了.", "source_row": 281, "speaker": "值班员"}, {"text": "（他将工单放进抽屉，又趴回登记簿上.）", "source_row": 281}],
	"recon.open": [{"text": "等一下，这个点怎么还在动？", "source_row": 293, "speaker": "侦察员"}, {"text": "（他敲了敲屏幕边缘，一只小虫爬到了桌上.）", "source_row": 293}, {"text": "哦，在这儿呢.", "source_row": 293, "speaker": "侦察员"}, {"text": "差点把它也当雷了？", "source_row": 293, "speaker": "玩家"}, {"text": "是啊，差点就标上去了.", "source_row": 293, "speaker": "侦察员"}],
	"recon.done": [{"text": "（侦察员核对了一遍读数，把结果转到你面前.）", "source_row": 295}, {"text": "【范围】内的雷都标出来了，扫到地图边缘就停，你照着这张看吧.", "source_row": 295, "speaker": "侦察员"}, {"text": "（地图更新雷位，尚未实际到访的房间仍不能回传.）", "source_row": 295}],
	"recon.revisit": [{"text": "刚才那张图你拿出来，哪儿没看懂我给你指.", "source_row": 296, "speaker": "侦察员"}, {"text": "（探头已经关上，他没有重新开机.）", "source_row": 296}],
	"rps.open": [{"text": "来来来，坐这边，别把它挤倒了.", "source_row": 308, "speaker": "闲客"}, {"text": "（他扶正旁边的稻草人，给你挪出一把椅子.）", "source_row": 308}, {"text": "你跟它玩什么呢？", "source_row": 308, "speaker": "玩家"}, {"text": "猜拳啊，可它老不出！", "source_row": 308, "speaker": "闲客"}],
	"rps.tie": [{"text": "哎怎么又一样了！这把不算，咱俩重来.", "source_row": 310, "speaker": "闲客"}],
	"rps.win": [{"text": "啧又猜着了……行，这分你的，手收回去，咱俩一起出啊.", "source_row": 311, "speaker": "闲客"}, {"text": "（他在你的分数下面添了一笔，眼睛还盯着你的手.）", "source_row": 311}],
	"rps.loss": [{"text": "哈哈这回抓着你了，这分归我！", "source_row": 312, "speaker": "闲客"}, {"text": "（他在自己那边画下一道，把记分纸往你面前推了推.）", "source_row": 312}],
	"rps.match_win": [{"text": "（他数出【奖金】枚黑币递过来，嘴里还念叨着刚才那一拳.）", "source_row": 313}, {"text": "拿去吧，我刚才真不该换……唉，都想好了又换.", "source_row": 313, "speaker": "闲客"}],
	"rps.match_loss": [{"text": "我去终于赢了！看见没这回可没赖你！", "source_row": 314, "speaker": "闲客"}, {"text": "（他把记分纸拍到稻草人面前，笑了半天才想起你还坐着.）", "source_row": 314}, {"text": "钱你揣着就行，说好了不要你的.下回路过再来找我啊！", "source_row": 314, "speaker": "闲客"}],
	"rps.pending": [{"text": "哎你回来了！刚才【玩家比分】比【对手比分】，我都记着呢，椅子给你留着，接着来？", "source_row": 315, "speaker": "闲客"}],
	"cage.open328": [{"text": "（你跨进房间，顶灯一盏盏亮起来，喇叭里突然响起一阵掌声.）", "source_row": 328}, {"text": "哪儿来的掌声？", "source_row": 328, "speaker": "玩家"}],
	"cage.open329": [{"text": "（铁闸在你背后砸了下来，把回去的路封住了.）", "source_row": 329}, {"text": "欢迎本场选手，入场即报名，比赛即将开始！", "source_row": 329, "speaker": "广播"}, {"text": "我就路过，你把门打开！", "source_row": 329, "speaker": "玩家"}, {"text": "观众朋友们，请将目光转向场内！", "source_row": 329, "speaker": "广播"}],
	"cage.open330": [{"text": "（对面的笼门才抬到一半，怪物已经挤了出来.）", "source_row": 330}, {"text": "本场对手已经就位，请双方保持距离，听到指令后再……", "source_row": 330, "speaker": "广播"}, {"text": "（怪物继续朝你走来.）", "source_row": 330}, {"text": "看来选手们都等不及了！", "source_row": 330, "speaker": "广播"}],
	"cage.open331": [{"text": "你倒是让它等等啊！", "source_row": 331, "speaker": "玩家"}, {"text": "申诉请在赛后提出，现在比赛开始！", "source_row": 331, "speaker": "广播"}],
	"cage.win": [{"text": "（掌声又响了起来，出口的铁闸缓缓升起.）", "source_row": 332}, {"text": "恭喜本场获胜选手，请从出口离场，为下一场比赛腾出场地！", "source_row": 332, "speaker": "广播"}],
	"cage.loss": [{"text": "本场比赛结束，请工作人员清理场地，下一位选手准备入场.", "source_row": 333, "speaker": "广播"}],
	"cage.revisit": [{"text": "（喇叭正在报下一场的幕，出口还开着，广播没有再叫住你.）", "source_row": 334}],
	"dice.open": [{"text": "坐啊", "source_row": 347, "speaker": "庄家"}, {"text": "对呀，规矩写在这儿呢，骰子你也可以看看.", "source_row": 347, "speaker": "庄家"}, {"text": "（他挪开压着价目的手，把骰子放到桌边.）", "source_row": 347}],
	"dice.loss": [{"text": "【点数】点啊，唉，这把差点运气.", "source_row": 349, "speaker": "庄家"}],
	"dice.invite": [{"text": "才坐热怎么就要走了，再玩一把呗，万一下把把前头的都赢回来呢？", "source_row": 350, "speaker": "庄家"}],
	"dice.win5": [{"text": "哟中了啊！", "source_row": 351, "speaker": "庄家"}],
	"dice.win6": [{"text": "六点？拿来我看看……", "source_row": 352, "speaker": "庄家"}, {"text": "（他拎起骰盅看了一眼，又伸手拨了拨骰子，才低头数钱.）", "source_row": 352}, {"text": "你数数.", "source_row": 352, "speaker": "庄家"}],
	"dice.pending": [{"text": "换个盅吧，这个沿口都毛了.", "source_row": 354, "speaker": "庄家"}, {"text": "（他收起骰盅，袖口挡住了骰子.等手移开，骰子已经换了个位置.）", "source_row": 354}],
	"dice.revisit": [{"text": "三把都玩完了，今天这桌就到这儿吧，下回再来.", "source_row": 355, "speaker": "庄家"}, {"text": "（他将骰盅扣进抽屉，把椅子往回收了收.）", "source_row": 355}],
	"altar.open": [{"text": "（石面亮起「奉血，取物」，槽口还卡着几片旧指甲，你的手在上面停了一下.）", "source_row": 367}],
	"altar.offer": [{"text": "（【供品】浮到台沿，旁边落着【黑币数】枚黑币，凹槽边亮出「【耗血】生命」.）", "source_row": 368}],
	"altar.done": [{"text": "（血顺着凹槽流进去，供品落了下来，黑币跟着滚向台边，你伸手拢住了它们.）", "source_row": 370}],
	"altar.next": [{"text": "（上一份供品才拿走，石面又托出下一份，凹槽边的价码也变了.）", "source_row": 371}],
	"altar.revisit": [{"text": "（石面凉了下去，你再碰它也没有反应.槽口的几片指甲还卡在那里.）", "source_row": 372}],
}

static func project(event: String, state: Dictionary, hints: Dictionary = {}) -> Dictionary:
	if not SPEAKERS.has(event):
		return {}
	var keys: Array = [event + ".open"]
	var complete := bool(state.get("completed", false))
	if complete:
		keys = [event + ".revisit"]
	match event:
		"information":
			if not complete and hints.get("information_discount", false):
				keys.append("information.discount")
		"shop":
			if hints.get("returning", false) or state.get("stage_awarded", false):
				var remaining: Array = state.get("offers", []).filter(func(offer: Dictionary) -> bool: return not offer.get("sold", false))
				keys = ["shop.empty" if remaining.is_empty() else "shop.stock"]
		"savings":
			var pending: Dictionary = hints.get("savings_pending", {})
			if complete:
				keys = ["savings.withdraw"] if state.get("last_result", {}).get("option_id", "") == "withdraw" else ["savings.thanks", "savings.same"]
			elif not pending.is_empty() and str(pending.get("room_key", "")) != str(state.get("room_key", "")):
				keys = ["savings.pending"]
		"seal":
			if not complete and hints.get("seal_discount", false):
				keys.append("seal.discount")
		"first_aid":
			if not complete:
				keys = ["first_aid.emergency" if _reward(state, "buy").get("base_pressure", 0) > 0 else "first_aid.normal"]
		"mechanism":
			if not complete:
				keys = ["mechanism.electric" if state.get("variant", "") == "electric" else "mechanism.mechanical"]
		"coil":
			if not complete and str(state.get("pending", {}).get("room_id", "")) == str(state.get("room_key", "")):
				keys = ["coil.pending"]
		"clock_in":
			var contract: Dictionary = state.get("contract", {})
			if not contract.is_empty():
				keys = ["clock_in.revisit"] if contract.get("claimed", false) else (["clock_in.progress"] if contract.get("new_rooms", {}).size() < 3 else [])
		"rps":
			if complete:
				keys = [] # No completed revisit dialogue in S3. Keep actual summary.
			elif not state.get("rounds", []).is_empty():
				keys = ["rps.pending"]
		"cage":
			if state.get("challenge_available", false):
				keys = ["cage.open328"]
			elif not complete:
				keys = ["cage.open328", "cage.open329", "cage.open330", "cage.open331"]
		"dice":
			if not complete and not state.get("rounds", []).is_empty():
				keys = ["dice.pending"]
		"altar":
			if not complete:
				keys = ["altar.next" if int(state.get("offer_count", 0)) > 0 else "altar.open"]
				if not state.get("requires_prepare", false):
					keys.append("altar.offer")
	return {"speaker": SPEAKERS[event], "dialogue": _render(keys, _view_values(state, hints)),
		"dialogue_source": {"id": "S3", "sheet": SOURCE_SHEET, "sha256": SOURCE_SHA256, "fragments": keys}}


static func response(event: String, action: String, facts: Dictionary, state: Dictionary) -> Array:
	var keys: Array = []
	match event:
		"information": keys = ["information.free" if action == "mine_count" else "information.paid"]
		"shop": keys = ["shop.refresh"] if action == "refresh" else []
		"savings": keys = ["savings.deposit" if action == "deposit" else "savings.withdraw"]
		"seal": keys = ["seal.done"]
		"relief": keys = ["relief." + action]
		"first_aid", "consign", "expand", "compress", "trader", "pawn", "recon": keys = [event + ".done"]
		"mechanism":
			if facts.has("success"):
				keys = ["mechanism.loss" if not facts.success else ("mechanism.electric_done" if facts.get("mechanism_variant", state.get("variant", "")) == "electric" else "mechanism.win")]
		"recycle": keys = ["recycle." + str(facts.get("operation", ""))]
		"coil": keys = ["coil.calibrate"] if action == "calibrate" else []
		"demine": keys = ["demine.hit" if facts.get("hit", false) else "demine.miss"]
		"clock_in": keys = ["clock_in." + action]
		"rps": keys = ["rps.match_win" if facts.match_win else "rps.match_loss"] if facts.has("match_win") else ["rps." + str(facts.get("outcome", ""))]
		"cage": keys = ["cage.win" if facts.win else "cage.loss"] if facts.has("win") else []
		"dice":
			keys = ["dice.win%d" % int(facts.get("face", 0))] if facts.get("win", false) else ["dice.loss"]
			if not facts.get("win", false) and int(facts.get("round", 0)) < 3:
				keys.append("dice.invite")
		"altar": keys = ["altar.done"] if action == "offer" else []
	var values := {}
	for pair in [["报价", "safe_income"], ["奖金", "black_income_gross"], ["点数", "face"]]:
		if facts.has(pair[1]):
			values[pair[0]] = str(facts[pair[1]])
	var item: Dictionary = facts.get("delivery", facts.get("output", {}))
	if item.has("display_name"):
		values["产物"] = str(item.display_name)
	if facts.has("scan_size"):
		values["范围"] = "%d×%d" % [int(facts.scan_size), int(facts.scan_size)]
	return _render(keys, values)


static func _view_values(state: Dictionary, hints: Dictionary) -> Dictionary:
	var values := {"可用口数": str(state.get("targets", []).size()),
		"玩家比分": str(state.get("wins", 0)), "对手比分": str(state.get("losses", 0))}
	var pending: Dictionary = hints.get("savings_pending", {})
	if pending.has("principal"):
		values["存款数"] = str(pending.principal)
	if state.has("contract"):
		values["剩余房间数"] = str(maxi(0, 3 - state.contract.get("new_rooms", {}).size()))
	if not state.get("requires_prepare", false):
		for pair in [["门槛", "threshold"], ["黑币数", "black_reward"], ["耗血", "hp_cost"]]:
			if state.has(pair[1]):
				values[pair[0]] = str(state[pair[1]])
		var names: Array[String] = []
		for item: Dictionary in state.get("rewards", []):
			if item.has("display_name"):
				names.append(str(item.display_name))
		if not names.is_empty():
			values["供品"] = "、".join(names)
		for option: Dictionary in state.get("options", []):
			if str(option.get("id", "")) == "refresh" and option.get("player_cost", {}).has("amount"):
				values["本次刷新费用"] = str(option.player_cost.amount)
	return values


static func _reward(state: Dictionary, action: String) -> Dictionary:
	for option: Dictionary in state.get("quote", {}).get("options", []):
		if str(option.get("id", option.get("option_id", ""))) == action:
			return option.get("reward", {})
	return {}


static func _render(keys: Array, values: Dictionary) -> Array:
	var lines: Array = []
	for key: String in keys:
		for original: Dictionary in FRAGMENTS.get(key, []):
			var line := original.duplicate(true)
			for token: String in values:
				line.text = str(line.text).replace("【" + token + "】", str(values[token]))
			# Never invent a value or leave a source-template instruction in the UI.
			if not str(line.text).contains("【"):
				lines.append(line)
	return lines
