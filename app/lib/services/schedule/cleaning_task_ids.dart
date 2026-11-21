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
      '把同处于一段连续工作、学习或讨论状态的相邻阶段收成沉浸式记录，归纳整段期间的核心事务与沟通内容；'
      '中间一两分钟的零碎分心插话若属同一大活动可顺滑吸纳，独立的 1~2 句无实质意义碎语标为 lowValue=true。';

  static const longPrompt =
      '你是录音多轮整理的长轮。输入是中轮已经整理好的阶段，不是两小时原始逐句。'
      '在不编造事实的前提下，把数十分钟到数小时处于同一状态（如持续工作开发/连续会议）的阶段归拢为长时段沉浸记录，'
      '严禁拆成一两分钟碎片；独立无意义的短句标为 lowValue=true。';

  static const all = [short, medium, long];
}
