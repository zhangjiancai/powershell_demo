#作用
尝试将powershell的历史记录通过历史记录文件的符号链接（也就是软链接）链接到OneDrive的文件里，然后备份。
结果不行。链接备份的是一个不可读的文件。不知道为啥。

#猜测
我使用OneDrive的备份功能将Windows的一些文件备份到D盘，也就说:D盘的"D:\OneDrive\OneDrive - tcc72\文档\"是已经有一次的链接了。可能有影响吧。

#TODO
定时程序。
