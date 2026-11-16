/// 清洗任务 id。放在独立文件里，避免调度器和 AppStore 互相引用。
library;

class CleaningTaskIds {
  static const short = 'clean.short';
  static const medium = 'clean.medium';
  static const long = 'clean.long';
  static const rollingHandler = 'rolling_clean';
  static const organizeHandler = 'organize_pass';

  static const mediumPrompt =
      '你是录音多轮整理的中轮。输入是短轮已经整理好的阶段，不是原始逐句。'
      '把同一话题的相邻阶段收成更连贯的较长段落，保留说话人、顺序和原文里的事实。'
      '不能合并的就分开。这是再合并，不是一套新的长会议算法。';

  static const longPrompt =
      '你是录音多轮整理的长轮。输入是中轮已经整理好的阶段，不是两小时原始逐句。'
      '在不编造事实的前提下，把同一场连续讨论收成更少的长段落。'
      '这只是保守的再摘要 / 再合并，完整的长会议算法还没有在这一轮做完。';

  static const all = [short, medium, long];
}
