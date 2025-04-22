import 'dart:io';
import 'package:path_provider/path_provider.dart';

// 取得 TXT 檔案的路徑
Future<File> _getTxtFile() async {
  final directory = await getApplicationDocumentsDirectory(); // 取得 App 的文件資料夾
  return File('${directory.path}/maxExpDir.txt');
}

// 寫入內容到檔案（追加寫入）
Future<void> writeToFile(String content) async {
  final file = await _getTxtFile();
  await file.writeAsString(content, mode: FileMode.append );
}

// 讀取檔案內容
Future<String> readFromFile() async {
  final file = await _getTxtFile();
  if (await file.exists()) {
    return await file.readAsString();
  }
  return ''; // 如果檔案不存在，返回空字串
}

// 清空檔案內容
Future<void> clearFile() async {
  final file = await _getTxtFile();
  if (await file.exists()) {
    await file.writeAsString('');
  }
}