import numpy as np

import matplotlib
matplotlib.use('tkagg')
import matplotlib.pyplot as plt

import seaborn as sns

sns.set()
plt.axis([ 0 , 50 , 0 , 50 ])

plt.xticks(fontsize = 15 )
plt.yticks(fontsize = 15 )

plt.xlabel("R" , fontsize = 30 )
plt.ylabel("P" , fontsize = 30 )

x,y = np.loadtxt("Pizza.txt" , skiprows = 1 , unpack = True )
plt.plot( x , y ,"bo")

plt.show()


